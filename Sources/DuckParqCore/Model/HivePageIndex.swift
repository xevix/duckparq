import Foundation

/// A hive dataset's files in a fixed order, with the bookkeeping needed to
/// address any row of it by offset.
///
/// This exists because `ORDER BY <partition key>` does not name a particular
/// row. A partition key is by nature very low cardinality — it is the thing the
/// dataset is physically divided by — so under that sort very nearly every row
/// ties with very nearly every other. Two pages read at two offsets are two
/// separate query executions, and nothing obliges DuckDB to break those ties the
/// same way twice. Paging a hive dataset that way shows some rows twice and
/// never shows others: measured at between a sixth and a third of the rows on
/// the 3000-row fixture, varying run to run.
///
/// The way out is to stop asking DuckDB to order anything. A hive dataset
/// already carries a total order that costs nothing to establish and cannot
/// drift:
///
/// 1. partitions, in the order of their keys' values, outermost key first;
/// 2. files within a partition, by name;
/// 3. rows within a file, in the order the file stores them.
///
/// The first two come from the paths alone — `parquet_file_metadata` reads
/// footers, never data, and answers in about two milliseconds for the fixture
/// and one for a 10M-row file. The third is a plain parquet scan, which DuckDB
/// emits in insertion order. So the whole order is deterministic, and no
/// `ORDER BY` is issued at all: there are no ties to break because there is
/// nothing to sort.
///
/// That order is a *refinement* of `ORDER BY <partition key>` rather than a
/// departure from it — every row still sits inside its own partition's run, so
/// the sort the header advertises is honoured. It just also settles the part
/// the ORDER BY left open.
@MainActor
public final class HivePageIndex {
    /// One file of the dataset, with what is known about it from its path and
    /// its footer.
    public struct File: Sendable, Equatable {
        public let path: String
        /// Rows the file holds, from its parquet footer. Every row in it,
        /// before any filter — see `rowCounts()` for the filtered answer.
        public let totalRows: Int
        /// Partition values parsed out of the path, outermost key first. Nil
        /// where the path carries DuckDB's `__HIVE_DEFAULT_PARTITION__`, which
        /// is how a NULL partition value is spelled on disk.
        public let partitionValues: [String?]

        public init(path: String, totalRows: Int, partitionValues: [String?]) {
            self.path = path
            self.totalRows = totalRows
            self.partitionValues = partitionValues
        }
    }

    /// A read of one file: where in it to start and how many rows to take.
    public struct Span: Sendable, Equatable {
        public let file: Int
        public let offset: Int
        public let count: Int

        public init(file: Int, offset: Int, count: Int) {
            self.file = file
            self.offset = offset
            self.count = count
        }
    }

    /// DuckDB's spelling of a NULL partition value on disk.
    ///
    /// `nonisolated`, along with the path parsing below it, because reading a
    /// key=value directory name is string work with no state behind it — the
    /// index is on the main actor for its session and its cached counts, and
    /// `HiveSummary` has neither.
    public nonisolated static let nullPartition = "__HIVE_DEFAULT_PARTITION__"

    public let files: [File]
    /// Partition keys, outermost first — the `["year", "region"]` of a
    /// `year=2024/region=us/` layout.
    public let keys: [String]

    private let source: DataSource
    private let session: DuckDBSession
    /// Rows per file matching the active filters, once something has needed to
    /// address a row by absolute offset. Nil until then — see `rowCounts()`.
    private var filteredRowCounts: [Int]?

    public init(files: [File], keys: [String], source: DataSource, session: DuckDBSession) {
        self.files = files
        self.keys = keys
        self.source = source
        self.session = session
    }

    /// Rows in the dataset before any filter — the sum of the footers, so this
    /// costs nothing and is known the moment the index is built.
    public var totalRows: Int { files.reduce(0) { $0 + $1.totalRows } }

    public var isEmpty: Bool { files.isEmpty }

    // MARK: - Building

    /// Read the dataset's file list and footers, and put them in paging order.
    ///
    /// Returns nil for anything that is not a hive-partitioned dataset, which
    /// is the caller's signal to page it the ordinary way.
    public static func build(
        source: DataSource,
        session: DuckDBSession
    ) async throws -> HivePageIndex? {
        guard case .dataset(let root) = source else { return nil }

        let batch = try await session.queryAll(
            "SELECT file_name, num_rows FROM parquet_file_metadata($1)",
            params: [source.readPath],
            limit: metadataRowLimit
        )
        // A truncated file list would index part of the dataset and quietly
        // page as though that were all of it — rows past the cut would simply
        // never be reachable. There is no way to tell a truncated read from one
        // that exactly filled the limit, so both fall back.
        guard batch.rowCount > 0, batch.rowCount < metadataRowLimit else { return nil }

        var parsed: [(File, [String])] = []
        parsed.reserveCapacity(batch.rowCount)
        var keys: [String]?

        for row in 0..<batch.rowCount {
            guard let path = batch.value(row: row, named: "file_name"),
                  let rows = batch.value(row: row, named: "num_rows").flatMap({ Int($0) })
            else { return nil }

            let (fileKeys, values) = partitionComponents(of: path, under: root)
            // Every file must sit at the same depth under the same keys, or
            // "the order of the partition columns" is not a thing this dataset
            // has and the ordinary paging path is the honest answer.
            guard !fileKeys.isEmpty else { return nil }
            if let keys {
                guard keys == fileKeys else { return nil }
            } else {
                keys = fileKeys
            }
            parsed.append((
                File(path: path, totalRows: rows, partitionValues: values),
                fileKeys
            ))
        }
        guard let keys else { return nil }

        let ordered = order(parsed.map(\.0), keyCount: keys.count)
        return HivePageIndex(files: ordered, keys: keys, source: source, session: session)
    }

    /// A dataset with this many files or more is past the point where holding
    /// an index of them is the cheap option, so it pages the ordinary way —
    /// with the ties that implies. Reaching this is what `build` treats as a
    /// list it cannot trust to be complete.
    public static let metadataRowLimit = 200_000

    /// The `key=value` pairs on a file's path below the dataset root, outermost
    /// first. `__HIVE_DEFAULT_PARTITION__` becomes nil, since that is what it
    /// means.
    public nonisolated static func partitionComponents(
        of path: String, under root: URL
    ) -> (keys: [String], values: [String?]) {
        let rootComponents = root.standardizedFileURL.pathComponents
        var components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.count > rootComponents.count,
           Array(components.prefix(rootComponents.count)) == rootComponents {
            components.removeFirst(rootComponents.count)
        }

        var keys: [String] = []
        var values: [String?] = []
        // The last component is the file itself, never a partition.
        for component in components.dropLast() {
            guard FileTree.isHivePartitionName(component),
                  let separator = component.firstIndex(of: "=")
            else { continue }
            let key = String(component[component.startIndex..<separator])
            let raw = String(component[component.index(after: separator)...])
            keys.append(key)
            values.append(raw == nullPartition ? nil : raw)
        }
        return (keys, values)
    }

    /// Put the files in the order the grid pages through them.
    ///
    /// Partition values are compared as numbers where every value of that key
    /// is one, and as text otherwise — which is what DuckDB's own hive type
    /// inference does, and it matters: sorting the paths as plain strings puts
    /// `month=10` between `month=1` and `month=2`, so the rows would come out
    /// in an order the `ORDER BY month` in the header flatly contradicts.
    ///
    /// Dates and timestamps need no special case. Hive writes them ISO-8601,
    /// where lexicographic order and chronological order agree.
    ///
    /// A NULL partition sorts last, matching DuckDB's `NULLS LAST` default for
    /// an ascending sort.
    public static func order(_ files: [File], keyCount: Int) -> [File] {
        let numeric = (0..<keyCount).map { level in
            files.allSatisfy { file in
                guard let value = file.partitionValues[safe: level] ?? nil else { return true }
                return Int(value) != nil
            }
        }
        let floating = (0..<keyCount).map { level in
            files.allSatisfy { file in
                guard let value = file.partitionValues[safe: level] ?? nil else { return true }
                return Double(value) != nil
            }
        }

        return files.sorted { left, right in
            for level in 0..<keyCount {
                let a = left.partitionValues[safe: level] ?? nil
                let b = right.partitionValues[safe: level] ?? nil
                switch (a, b) {
                case (nil, nil): continue
                case (nil, _): return false   // NULLS LAST
                case (_, nil): return true
                case (let a?, let b?):
                    if a == b { continue }
                    if numeric[level], let a = Int(a), let b = Int(b) { return a < b }
                    if floating[level], let a = Double(a), let b = Double(b) { return a < b }
                    return a < b
                }
            }
            return left.path < right.path
        }
    }

    // MARK: - Addressing

    /// Rows per file, counting only what the filters admit.
    ///
    /// Unfiltered this is the footers, which are already in hand. Filtered it
    /// is one grouped pass over the dataset — the same work as the `count(*)`
    /// that reports the total, so it is done once and kept rather than asked
    /// per file. Deliberately not done when the index is built: a window from
    /// row 0 never needs it, so opening a filtered dataset still shows its
    /// first page without waiting for a pass over the whole thing.
    public func rowCounts(filters: [Filter]) async throws -> [Int] {
        let active = filters.filter { $0.isEnabled && $0.isComplete }
        guard !active.isEmpty else { return files.map(\.totalRows) }
        if let filteredRowCounts { return filteredRowCounts }

        let query = SQLBuilder.rowCountsByFile(source: source, filters: active)
        let batch = try await session.queryAll(
            query.sql, params: query.params, limit: Self.metadataRowLimit
        )
        var byPath: [String: Int] = [:]
        byPath.reserveCapacity(batch.rowCount)
        for row in 0..<batch.rowCount {
            guard let path = batch.value(row: row, named: "file_name"),
                  let count = batch.value(row: row, named: "row_count").flatMap({ Int($0) })
            else { continue }
            byPath[path] = count
        }
        // A file every row of which was filtered out contributes no group, and
        // so contributes zero rows rather than being missing.
        let counts = files.map { byPath[$0.path] ?? 0 }
        filteredRowCounts = counts
        return counts
    }

    /// Forget the filtered counts, because the filters changed under them.
    public func invalidateCounts() {
        filteredRowCounts = nil
    }

    /// Which files hold `[start, start + count)`, given each file's row count.
    ///
    /// Pure arithmetic — split out from the reading so it can be checked
    /// without a database.
    public static func spans(start: Int, count: Int, rowCounts: [Int]) -> [Span] {
        guard count > 0, start >= 0 else { return [] }
        var spans: [Span] = []
        var consumed = 0
        var remaining = count
        var cursor = start

        for (index, rows) in rowCounts.enumerated() {
            if remaining <= 0 { break }
            let fileStart = consumed
            consumed += rows
            guard cursor < consumed else { continue }
            let offset = cursor - fileStart
            let take = min(rows - offset, remaining)
            guard take > 0 else { continue }
            spans.append(Span(file: index, offset: offset, count: take))
            cursor += take
            remaining -= take
        }
        return spans
    }

    // MARK: - Reading

    /// Rows read from the dataset, with the column names they arrived under —
    /// the grid borrows those until DESCRIBE lands.
    public struct Page: Sendable {
        public var columns: [String]
        public var rows: [[String?]]

        public init(columns: [String] = [], rows: [[String?]] = []) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The rows at `[start, start + count)` of the dataset, in file order.
    ///
    /// No `ORDER BY` is issued: the order is the file list, and within a file
    /// it is the scan's own order. That is the whole point — there is nothing
    /// for DuckDB to break ties in, so two reads of adjacent pages cannot
    /// disagree about which rows they hold.
    public func read(
        start: Int, count: Int, filters: [Filter], columnCount: Int
    ) async throws -> Page {
        guard count > 0, !files.isEmpty else { return Page() }
        let active = filters.filter { $0.isEnabled && $0.isComplete }

        // A window from row 0 with a filter needs no counts at all: read files
        // in order and stop once the window is full. This is what keeps opening
        // a filtered dataset as fast as it was — the grouped count below is a
        // pass over the whole dataset, and the first page must not wait for one.
        //
        // Every other window has to know where the rows before it are, so it
        // pays for the counts. Unfiltered that is the footers, already in hand.
        let readsWholeFilesFromTheStart = (start == 0 && !active.isEmpty)
        let spans: [Span]
        if readsWholeFilesFromTheStart {
            spans = []
        } else {
            let counts = try await rowCounts(filters: filters)
            spans = Self.spans(start: start, count: count, rowCounts: counts)
        }

        var page = Page()
        page.rows.reserveCapacity(count)

        func take(_ span: Span) async throws {
            let read = try await read(span, filters: active, columnCount: columnCount)
            if page.columns.isEmpty { page.columns = read.columns }
            page.rows += read.rows
        }

        if readsWholeFilesFromTheStart {
            for file in files.indices where page.rows.count < count {
                // How much of the window is still unfilled — not how much this
                // file holds, which is the thing not yet known.
                try await take(Span(file: file, offset: 0, count: count - page.rows.count))
            }
        } else {
            for span in spans { try await take(span) }
        }
        return page
    }

    private func read(
        _ span: Span, filters: [Filter], columnCount: Int
    ) async throws -> Page {
        let query = SQLBuilder.rows(
            file: files[span.file].path,
            within: source,
            filters: filters,
            limit: span.count,
            offset: span.offset
        )
        let batch = try await session.queryAll(
            query.sql, params: query.params, limit: span.count
        )
        let width = max(batch.columns.count, columnCount, 1)
        var rows: [[String?]] = []
        rows.reserveCapacity(batch.rowCount)
        for row in 0..<batch.rowCount {
            let start = row * width
            rows.append(Array(batch.cells[start..<min(start + width, batch.cells.count)]))
        }
        return Page(columns: batch.columns, rows: rows)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
