import Foundation

/// One value a column takes, and how many rows carry it.
public struct DistinctValue: Sendable, Equatable, Hashable {
    public let value: String
    public let count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// What a lazily-probed column filter should show.
public enum FilterAffordance: Sendable, Equatable {
    /// Few enough distinct values to pick from a list.
    ///
    /// The values are the column's complete, exact set — not a sample of it —
    /// so there is nothing for the UI to qualify, and the counts are the real
    /// row counts. `nullCount` is how many rows are NULL, zero when none are.
    case dropdown(values: [DistinctValue], nullCount: Int)
    /// Too many distinct values (or the type isn't enumerable) — use operators.
    case comparison
}

/// A column's distinct values in order, held so that typing into an equality
/// filter can be completed without a query per keystroke.
public struct DistinctValueIndex: Sendable, Equatable {
    /// How many completions an equality filter offers. Ten is what fits under a
    /// text field without the popover becoming a list you scroll.
    public static let suggestionLimit = 10

    /// Ascending and deduplicated, with NULL dropped.
    public let values: [String]

    /// False when the column has more distinct values than the index was
    /// allowed to hold.
    ///
    /// `values` is then the lexicographically *first* of them, which is a
    /// meaningful thing to have: it answers exactly for anything up to its last
    /// entry, and knows nothing at all beyond it. The distinction matters
    /// because "no completions" and "no completions I can see from here" look
    /// identical on screen — see `TableModel.valueSuggestions(for:startingAt:)`,
    /// which asks DuckDB for that stretch rather than showing an empty list.
    public let isComplete: Bool

    public init(values: [String], isComplete: Bool) {
        self.values = values
        self.isComplete = isComplete
    }

    /// The values at or after `typed`, in order.
    ///
    /// "At or after" rather than "starting with": what a half-typed value wants
    /// offered is where it lands among the column's values, and a prefix match
    /// has nothing to say the moment a typo takes it off the list. A value
    /// equal to `typed` is kept, so completing an already-exact value is a
    /// no-op instead of a jump to the next one along.
    public func suggestions(startingAt typed: String, limit: Int = suggestionLimit) -> [String] {
        // Lower bound by bisection — this runs on every keystroke.
        var low = 0
        var high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if values[middle] < typed { low = middle + 1 } else { high = middle }
        }
        return Array(values[low..<min(low + max(limit, 0), values.count)])
    }
}

/// Schema, counts and cardinality lookups. These run on their own session so a
/// slow grid query never delays a schema panel, and vice versa.
public struct Probe: Sendable {
    /// How many distinct values a column may have and still be picked from a
    /// list rather than typed against.
    ///
    /// The ceiling is about what a person can usefully scan, not about what the
    /// query costs: five hundred station codes or airport identifiers are still
    /// a set you pick from, and the alternative is typing one exactly. The
    /// probe's cost barely moves — the hash table is five hundred groups
    /// instead of fifty — so the screening read is what keeps genuinely
    /// high-cardinality columns from ever reaching the exact question.
    public static let defaultMaxDistinct = 500

    private let session: DuckDBSession

    public init(session: DuckDBSession) {
        self.session = session
    }

    public func columns(of source: DataSource) async throws -> [ColumnInfo] {
        let query = SQLBuilder.describe(source: source)
        let batch = try await session.queryAll(query.sql, params: query.params)
        return (0..<batch.rowCount).compactMap { row in
            guard let name = batch.value(row: row, named: "column_name") else { return nil }
            let type = batch.value(row: row, named: "column_type") ?? "VARCHAR"
            let nullable = (batch.value(row: row, named: "null") ?? "YES").uppercased() != "NO"
            return ColumnInfo(name: name, typeName: type, isNullable: nullable)
        }
    }

    public func rowCount(of source: DataSource, filters: [Filter] = []) async throws -> Int {
        try await count(SQLBuilder.rowCount(source: source, filters: filters))
    }

    /// Run a prepared `count(*)` query. On parquet this is answered largely from
    /// file metadata, so it stays cheap even on files far too large to load.
    public func count(_ query: BoundSQL) async throws -> Int {
        let batch = try await session.queryAll(query.sql, params: query.params, limit: 1)
        guard batch.rowCount > 0, let text = batch[0, 0], let value = Int(text) else { return 0 }
        return value
    }

    /// Decide which filter UI a column deserves, from how many distinct values
    /// it actually has.
    ///
    /// Run when the filter popover opens rather than on file select: probing
    /// every column up front would turn "click a file and look at it" into a
    /// scan per column, which is exactly what this app exists to avoid.
    ///
    /// Two questions, in cost order, and the answer is exact either way:
    ///
    /// 1. **A bounded read of the head.** More than `maxDistinct` values in any
    ///    subset proves more than `maxDistinct` values in the column, so this
    ///    can reject a column outright — cheaply, and without ever being able to
    ///    wrongly admit one. It is a rejection filter, not an estimate.
    /// 2. **The real distinct set**, for whatever survives. `DISTINCT` is a
    ///    blocking hash aggregate, so this reads the column; it is only reached
    ///    for columns that look enumerable, where the hash table stays small and
    ///    parquet's dictionary encoding makes the scan cheap.
    ///
    /// The values shown are therefore the column's, complete. An earlier version
    /// showed the head sample's values directly and labelled them "from the
    /// first 200,000 rows" — which on a column whose early rows are all NULL
    /// meant an empty list, and a caveat in place of the answer.
    public func filterAffordance(
        for column: ColumnInfo,
        in source: DataSource,
        maxDistinct: Int = Probe.defaultMaxDistinct,
        screenRows: Int = 200_000
    ) async throws -> FilterAffordance {
        guard column.kind != .nested, column.kind != .binary else { return .comparison }

        let screen = SQLBuilder.distinctValues(
            source: source, column: column,
            sampleRows: screenRows, maxDistinct: maxDistinct
        )
        let screened = try await session.queryAll(screen.sql, params: screen.params, limit: maxDistinct + 1)
        // One more row than the cap means "too many to enumerate".
        guard screened.rowCount <= maxDistinct else { return .comparison }

        let exact = SQLBuilder.valueCounts(source: source, column: column, maxDistinct: maxDistinct)
        let batch = try await session.queryAll(exact.sql, params: exact.params, limit: maxDistinct + 1)
        guard batch.rowCount <= maxDistinct else { return .comparison }

        var values: [DistinctValue] = []
        var nullCount = 0
        for row in 0..<batch.rowCount {
            let occurrences = Int(batch[row, 1] ?? "") ?? 0
            if let value = batch[row, 0] {
                values.append(DistinctValue(value: value, count: occurrences))
            } else {
                nullCount = occurrences
            }
        }
        // Nothing to choose from is not a dropdown. A column with no values at
        // all is an empty source, and offering an empty list would look exactly
        // like a broken one.
        guard !values.isEmpty || nullCount > 0 else { return .comparison }
        // Alphabetical, not by frequency: a list you are picking from should be
        // in the order you would look something up in, and the counts are right
        // there to be read.
        return .dropdown(values: values.sorted { $0.value < $1.value }, nullCount: nullCount)
    }

    /// How many of a column's distinct values are held for completing an
    /// equality filter.
    ///
    /// Twenty times `defaultMaxDistinct`, because the two caps answer different
    /// questions. That one asks what a person can usefully *scan*; this one only
    /// has to be searched, so the ceiling is memory — ten thousand values is a
    /// few hundred kilobytes of strings, and holding them turns every keystroke
    /// after the first into a binary search instead of a scan of the column.
    public static let defaultSuggestionIndexLimit = 10_000

    /// Read a column's distinct values in order, up to `limit` of them.
    ///
    /// One read, cached by the caller, in exchange for every later completion
    /// being local. Unlike `filterAffordance` there is no screening step: the
    /// answer is useful truncated, so there is nothing to reject a column for.
    public func distinctValueIndex(
        for column: ColumnInfo,
        in source: DataSource,
        limit: Int = Probe.defaultSuggestionIndexLimit
    ) async throws -> DistinctValueIndex {
        // One row past the limit, which is how a truncated index is told from
        // one that happens to hold the column exactly.
        let query = SQLBuilder.orderedDistinctValues(source: source, column: column, limit: limit + 1)
        let batch = try await session.queryAll(query.sql, params: query.params, limit: limit + 1)

        let held = min(batch.rowCount, limit)
        var values: [String] = []
        values.reserveCapacity(held)
        for row in 0..<held {
            if let value = batch[row, 0] { values.append(value) }
        }
        // Re-sorted here because the lookups against it are Swift comparisons:
        // DuckDB orders VARCHAR by bytes, which agrees with `<` on ASCII and
        // can disagree on anything else. SQL still does the ordering above, so
        // a truncated index holds the first values rather than an arbitrary set.
        return DistinctValueIndex(values: values.sorted(), isComplete: batch.rowCount <= limit)
    }

    /// A column's distinct values at or after `typed`, straight from DuckDB.
    ///
    /// The fallback for a column with more distinct values than an index holds,
    /// asked only once the typing has run past the end of what it holds.
    public func valueSuggestions(
        for column: ColumnInfo,
        in source: DataSource,
        startingAt typed: String,
        limit: Int = DistinctValueIndex.suggestionLimit
    ) async throws -> [String] {
        let query = SQLBuilder.orderedDistinctValues(
            source: source, column: column, startingAt: typed, limit: limit
        )
        let batch = try await session.queryAll(query.sql, params: query.params, limit: limit)
        return (0..<batch.rowCount).compactMap { batch[$0, 0] }
    }

    public func fileMetadata(of source: DataSource) async throws -> RowBatch {
        let query = SQLBuilder.fileMetadata(source: source)
        return try await session.queryAll(query.sql, params: query.params, limit: 64)
    }

    public func columnMetadata(of source: DataSource) async throws -> RowBatch {
        let query = SQLBuilder.rowGroupMetadata(source: source)
        return try await session.queryAll(query.sql, params: query.params, limit: 4096)
    }

    public func keyValueMetadata(of source: DataSource) async throws -> RowBatch {
        let query = SQLBuilder.keyValueMetadata(source: source)
        return try await session.queryAll(query.sql, params: query.params, limit: 256)
    }
}
