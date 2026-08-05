import Foundation

/// Drives the data grid: what to read, how it's filtered and ordered, and the
/// rows loaded so far.
///
/// Every change of source, filter or sort re-runs the query in DuckDB. Nothing
/// here reorders or filters rows already loaded — the grid holds a window into a
/// result, not the result, so sorting that window locally would silently present
/// a reordered fragment as the file's true order.
@MainActor
@Observable
public final class TableModel {
    public enum Mode: Equatable {
        case empty
        case source(DataSource)
        /// A query typed in the SQL editor. Column filters don't apply.
        case sql(String)
    }

    public struct GridRow: Identifiable, Sendable {
        public let id: Int
        public let cells: [String?]

        public init(id: Int, cells: [String?]) {
            self.id = id
            self.cells = cells
        }
    }

    /// The opening window, and the size of a single fetch from a cursor. Large
    /// enough that scrolling rarely waits, small enough that the first
    /// screenful appears promptly.
    public static let pageSize = 500
    /// Start fetching once the viewport gets within this many rows of the end.
    public static let prefetchDistance = 150
    /// Memory guard. Past this the user has to ask for more explicitly.
    public static let loadedRowCap = 200_000

    public private(set) var mode: Mode = .empty
    public private(set) var columns: [ColumnInfo] = []
    public private(set) var rows: [GridRow] = []
    public private(set) var sort: [SortKey] = []
    public private(set) var filters: [Filter] = []

    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var reachedEnd = false
    public private(set) var hitRowCap = false
    public private(set) var errorMessage: String?
    public private(set) var totalRowCount: Int?
    public private(set) var isCountingRows = false

    /// When the query now on screen started, while it is still running. The
    /// status bar renders the elapsed time from this rather than the model
    /// publishing a tick, so a running query costs no redraws of its own.
    public private(set) var queryStartedAt: Date?
    /// How long the last completed load took, kept so the number stays visible
    /// after the query finishes.
    public private(set) var lastQueryDuration: TimeInterval?
    /// The last load ended because the user stopped it, not because it finished.
    public private(set) var wasCancelled = false
    /// The rows on screen came from `PreviewCache` rather than a fresh read.
    public private(set) var servedFromCache = false

    /// How many rows the grid asks DuckDB for — a real `LIMIT` on the query.
    ///
    /// This is what makes sorting a file far too large to sort usable: with the
    /// clause present, `ORDER BY … LIMIT 500` plans as a Top-N, so DuckDB keeps
    /// 500 rows as it scans instead of ordering three billion of them and
    /// discarding all but the first screenful. Without it, the first row cannot
    /// appear until the entire sort has finished.
    ///
    /// The price is that widening the window re-runs the query rather than
    /// reading further along an open stream. It therefore **doubles** rather
    /// than stepping by a page, so reaching row N costs a logarithmic number of
    /// re-runs and a total of about 2N rows transferred — instead of a re-run
    /// per page. Browsing is what this app is for; reading a million rows in
    /// order is what the export button is for.
    public private(set) var windowSize = pageSize

    private let gridSession: DuckDBSession
    /// Schema and cardinality lookups.
    private let probe: Probe
    /// Row counting, deliberately on its own session.
    ///
    /// A `DuckDBSession` runs everything on one serial queue, so sharing a
    /// session is sharing a queue: a `count(*)` over three billion rows would
    /// hold up the `DESCRIBE` beside it, and "these run concurrently" would be
    /// true of the Swift tasks and false of the work.
    private let counter: Probe
    /// Column cardinality for filter popovers, which can mean reading a column.
    private let filterProbe: Probe
    private let cache: PreviewCache

    private var cursor: QueryCursor?
    /// Bumped on every reload; results from an older generation are discarded.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    private var schemaTask: Task<Void, Never>?

    /// Where to file this result once it has both a page and a count.
    private var pendingCacheKey: SourceFingerprint?
    private var loadedSource: DataSource?
    /// Raised by `continuePastCap()`, so the memory guard is the user's to lift.
    private var rowCap = TableModel.loadedRowCap
    /// What DuckDB's parser made of the statement in `.sql` mode. Only `EXPLAIN`
    /// matters: it is the one read-only statement that cannot be selected from,
    /// so it is the one that cannot be windowed.
    private var sqlStatementKind: StatementKind = .select

    public init(
        gridSession: DuckDBSession,
        metaSession: DuckDBSession,
        countSession: DuckDBSession,
        filterSession: DuckDBSession,
        cache: PreviewCache = .shared
    ) {
        self.gridSession = gridSession
        self.probe = Probe(session: metaSession)
        self.counter = Probe(session: countSession)
        self.filterProbe = Probe(session: filterSession)
        self.cache = cache
    }

    // MARK: - Column metadata

    /// Column names in display order, taken from the loaded rows when in SQL
    /// mode (where DESCRIBE of the source doesn't apply).
    public var displayColumns: [ColumnInfo] { columns }

    public func column(named name: String) -> ColumnInfo? {
        columns.first { $0.name == name }
    }

    /// The file or dataset being browsed, or nil in SQL mode.
    public var currentSource: DataSource? {
        if case .source(let source) = mode { return source }
        return nil
    }

    public var isSQLMode: Bool {
        if case .sql = mode { return true }
        return false
    }

    public func sortDirection(for column: String) -> SortDirection? {
        sort.first { $0.column == column }?.direction
    }

    public func sortOrdinal(for column: String) -> Int? {
        guard sort.count > 1, let index = sort.firstIndex(where: { $0.column == column }) else {
            return nil
        }
        return index + 1
    }

    /// Changes with anything that alters the SQL behind the view, so the editor
    /// can re-seed itself when a filter or sort moves under it.
    public var viewSignature: String {
        var parts: [String]
        switch mode {
        case .empty: parts = ["empty"]
        case .source(let source): parts = ["src", source.readPath]
        case .sql(let text): parts = ["sql", text]
        }
        parts += filters.filter { $0.isEnabled && $0.isComplete }.map(\.summary).sorted()
        parts += sort.map { "\($0.column) \($0.direction.rawValue)" }
        return parts.joined(separator: "\u{1F}")
    }

    // MARK: - Actions

    public func open(_ source: DataSource) {
        // A different file means the old schema no longer describes the cells,
        // so it has to go before the new result can borrow column names.
        if loadedSource != source {
            columns = []
            loadedSource = nil
        }
        mode = .source(source)
        filters = []
        sort = []
        reload()
    }

    /// Run a query from the SQL editor, if it is allowed to run.
    ///
    /// This is the only way `mode` becomes `.sql`, and it checks the statement
    /// against `SQLPolicy` before doing so. That ordering is what makes the
    /// read-only guarantee structural rather than a convention callers have to
    /// remember: everything `reload()` later derives from `.sql` — the sorted
    /// re-query, the row count, the export — is built from text that has
    /// already been parsed and accepted.
    public func runSQL(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Invalidate any load in flight so its results can't land after this.
        // The rows on screen stay put until the new query is cleared to run —
        // a rejected query should leave what you were looking at alone.
        generation += 1
        let generation = self.generation
        errorMessage = nil
        isLoading = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            let kinds: [StatementKind]
            do {
                kinds = try await self.gridSession.statementKinds(trimmed)
                try SQLPolicy.validateReadOnly(kinds)
            } catch {
                guard generation == self.generation else { return }
                self.isLoading = false
                self.report(error)
                return
            }
            guard generation == self.generation else { return }
            self.sqlStatementKind = kinds.first ?? .select
            self.mode = .sql(trimmed)
            self.filters = []
            self.sort = []
            self.columns = []
            self.reload()
        }
    }

    public func clear() {
        mode = .empty
        columns = []
        rows = []
        filters = []
        sort = []
        errorMessage = nil
        totalRowCount = nil
        loadedSource = nil
        pendingCacheKey = nil
        windowSize = Self.pageSize
        rowCap = Self.loadedRowCap
        isLoading = false
        isLoadingMore = false
        isCountingRows = false
        rowsAreStale = false
        queryStartedAt = nil
        cancelInFlight()
    }

    /// Cycle a column's sort: ascending → descending → unsorted.
    ///
    /// `additive` (shift-click) appends a secondary key instead of replacing.
    /// Each transition re-issues the query with a new ORDER BY.
    public func toggleSort(column: String, additive: Bool = false) {
        if let index = sort.firstIndex(where: { $0.column == column }) {
            switch sort[index].direction {
            case .ascending:
                sort[index].direction = .descending
            case .descending:
                sort.remove(at: index)
            }
            if !additive, sort.count > 1 {
                sort = sort.filter { $0.column == column }
            }
        } else {
            let key = SortKey(column: column, direction: .ascending)
            sort = additive ? sort + [key] : [key]
        }
        reload(keepingRows: true)
    }

    public func clearSort() {
        guard !sort.isEmpty else { return }
        sort = []
        reload(keepingRows: true)
    }

    /// Narrow to a value seen in the grid — what right-clicking a cell does.
    ///
    /// It adds to the column's existing value filter rather than replacing it,
    /// so picking a second value from a second row widens the selection the way
    /// ticking a second box in the popover does. A comparison filter on the same
    /// column is replaced, since there is nothing to add a value to.
    ///
    /// `nil` means the cell was NULL, which is a value to filter by like any
    /// other and not the absence of one.
    public func filter(column: ColumnInfo, matching value: String?) {
        let existing = filters.first { $0.column.name == column.name }
        var values: Set<String> = []
        var includeNull = false
        if let existing, case .anyOf(let current, let currentNull) = existing.mode {
            values = current
            includeNull = currentNull
        }
        if let value {
            values.insert(value)
        } else {
            includeNull = true
        }
        upsert(filter: Filter(
            id: existing?.id ?? UUID(),
            column: column,
            mode: .anyOf(values, includeNull: includeNull)
        ))
    }

    public func upsert(filter: Filter) {
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters[index] = filter
        } else {
            filters.append(filter)
        }
        reload(keepingRows: true)
    }

    public func removeFilter(id: Filter.ID) {
        guard filters.contains(where: { $0.id == id }) else { return }
        filters.removeAll { $0.id == id }
        reload(keepingRows: true)
    }

    public func clearFilters() {
        guard !filters.isEmpty else { return }
        filters = []
        reload(keepingRows: true)
    }

    /// What the filter popover for a column should offer.
    ///
    /// Cached against the source's fingerprint, because establishing that a
    /// column really does have few distinct values means reading it — the one
    /// question here a bounded read cannot answer. Runs on its own session so a
    /// slow one cannot hold up the schema lookup for the next file you click.
    public func filterAffordance(for column: ColumnInfo) async throws -> FilterAffordance {
        guard case .source(let source) = mode else { return .comparison }

        let fingerprint = await Task.detached(priority: .userInitiated) {
            SourceFingerprint.compute(for: source)
        }.value
        if let fingerprint, let cached = cache.affordance(for: fingerprint, column: column.name) {
            return cached
        }

        let affordance = try await filterProbe.filterAffordance(for: column, in: source)
        if let fingerprint {
            cache.storeAffordance(affordance, for: fingerprint, column: column.name)
        }
        return affordance
    }

    // MARK: - Loading

    /// The query the grid is currently showing, for export and for the SQL
    /// editor's "edit this query" affordance.
    public var currentQuery: BoundSQL? {
        switch mode {
        case .empty:
            return nil
        case .source(let source):
            return SQLBuilder.rows(source: source, filters: filters, sort: sort)
        case .sql(let text):
            return BoundSQL(sql: SQLBuilder.sorted(rawSQL: text, sort: sort), params: [])
        }
    }

    /// `currentQuery` bounded to the window the grid is showing.
    ///
    /// The window is applied here rather than folded into `currentQuery`
    /// because it belongs to the viewport: export means every matching row, the
    /// row count counts every matching row, and the SQL offered in the editor is
    /// the query without a limit the user did not write.
    private var windowedQuery: BoundSQL? {
        guard let query = currentQuery else { return nil }
        guard !isExplain else { return query }
        return SQLBuilder.windowed(query, limit: windowSize)
    }

    /// An `EXPLAIN` in the editor.
    ///
    /// It is the one read-only statement DuckDB will not let you select from,
    /// so neither the row window nor the bridge's `COLUMNS(*)::VARCHAR` wrap can
    /// be applied — both are a `SELECT` over the statement, and both turn it
    /// into a parse error. Its output is already text, and a handful of rows, so
    /// it needs neither. Decided from the kind DuckDB's parser reported, not by
    /// looking at the SQL.
    private var isExplain: Bool { isSQLMode && sqlStatementKind == .explain }

    /// Whether the result needs DuckDB to render its columns as text.
    private var rendersAsText: Bool { !isExplain }

    /// The current view expressed as SQL a person can read and edit.
    ///
    /// This is what the editor is seeded with when it opens over a selected
    /// file: the same source, filters and sort the grid is using, with the path
    /// and filter operands written out as literals. In SQL mode it is the user's
    /// own text, unchanged — their query is already the thing driving the view.
    public var editableSQL: String? {
        switch mode {
        case .empty:
            return nil
        case .source(let source):
            return SQLBuilder.editableRows(source: source, filters: filters, sort: sort)
        case .sql(let text):
            return text
        }
    }

    /// Anything is in flight that the user could reasonably want to stop.
    public var isBusy: Bool { isLoading || isLoadingMore || isCountingRows }

    /// Stop everything in flight, keeping whatever is already on screen.
    ///
    /// This interrupts the query inside DuckDB rather than just abandoning the
    /// Swift task — otherwise a cancelled sort of a huge file would keep a core
    /// busy producing a result nobody is going to read.
    public func cancel() {
        guard isBusy else { return }
        generation += 1
        cancelInFlight()
        stopTiming()
        isLoading = false
        isLoadingMore = false
        isCountingRows = false
        wasCancelled = true
        // The window stays where it is, so scrolling does not immediately
        // re-issue the query the user just stopped.
        reachedEnd = true
        pendingCacheKey = nil
        rowsAreStale = false
    }

    private func cancelInFlight() {
        loadTask?.cancel()
        loadTask = nil
        countTask?.cancel()
        countTask = nil
        schemaTask?.cancel()
        schemaTask = nil
        // Stop the query that is actually running rather than letting it finish
        // into a result nobody will read.
        gridSession.interrupt()
        if let cursor {
            Task { await cursor.close() }
        }
        cursor = nil
    }

    /// Re-run the current query.
    ///
    /// `keepingRows` leaves the rows on screen in place until the replacements
    /// arrive. Clearing them first is what made a header click flash the grid
    /// empty and then repopulate: re-sorting shows the same rows in a different
    /// order, so blanking the view says something untrue about the data for as
    /// long as the query takes. New rows replace the old ones the moment the
    /// first page lands, and the header still shows the new sort immediately, so
    /// nothing is misrepresented in the meantime — the status bar says the query
    /// is running.
    public func reload(keepingRows: Bool = false) {
        // A fresh look at a query starts from the opening window again, however
        // far the last one had been widened.
        windowSize = Self.pageSize
        rowCap = Self.loadedRowCap
        runQuery(keepingRows: keepingRows, widening: false)
    }

    /// Issue the current window.
    ///
    /// `widening` distinguishes "show me more of this" from "show me this": the
    /// row count, the schema and the cache lookup all belong to the query, not
    /// to the window, so they are not repeated when only the limit grew.
    private func runQuery(keepingRows: Bool, widening: Bool) {
        generation += 1
        let generation = self.generation
        cancelInFlight()

        if !keepingRows { rows = [] }
        rowsAreStale = keepingRows && !rows.isEmpty
        reachedEnd = false
        errorMessage = nil
        isLoading = !widening
        isLoadingMore = widening
        wasCancelled = false
        queryStartedAt = Date()
        lastQueryDuration = nil

        if !widening {
            hitRowCap = false
            servedFromCache = false
            pendingCacheKey = nil
            totalRowCount = nil
        }

        guard let query = windowedQuery else {
            isLoading = false
            isLoadingMore = false
            isCountingRows = false
            stopTiming()
            return
        }

        if !widening { isCountingRows = true }
        loadTask = Task { [weak self] in
            await self?.performInitialLoad(query: query, generation: generation, widening: widening)
        }
    }

    /// Rows on screen belong to the previous query and are replaced, not
    /// appended to, when the next page arrives.
    private var rowsAreStale = false

    private func performInitialLoad(query: BoundSQL, generation: Int, widening: Bool) async {
        if !widening {
            // A cache hit has to be settled before anything is issued, or the
            // work it is meant to avoid is already underway.
            if let key = await fingerprintForCaching() {
                guard generation == self.generation else { return }
                if let cached = cache.preview(for: key) {
                    apply(cached, generation: generation)
                    return
                }
                pendingCacheKey = key
            }
            guard generation == self.generation else { return }

            // Schema, preview and total row count are three independent
            // questions. They used to be asked in a chain, so a DESCRIBE across
            // a thousand-file dataset held up rows that DuckDB could already
            // have produced. Each now renders the moment it can.
            startSchemaLoad(generation: generation)
            startRowCount(generation: generation)
        }

        let target = windowSize
        do {
            let cursor = try await gridSession.openCursor(
                query.sql, params: query.params, renderAsText: rendersAsText
            )
            guard generation == self.generation else {
                await cursor.close()
                return
            }
            self.cursor = cursor

            // Until DESCRIBE lands — and always in SQL mode, where there is no
            // DESCRIBE to lean on — column identity comes from the result
            // itself. Types are unknown at that point, hence VARCHAR.
            if columns.isEmpty {
                columns = cursor.columnNames.map { ColumnInfo(name: $0, typeName: "VARCHAR") }
            }

            // Collected in full and committed in one step. The window is a
            // single coherent result, so the grid never shows part of the new
            // one stitched onto part of the old — which is also what keeps a
            // widened window free of the duplicates that `LIMIT`/`OFFSET`
            // paging produces when a sort has ties.
            var collected: [[String?]] = []
            collected.reserveCapacity(target)
            while collected.count < target {
                let page = try await cursor.fetch(maxRows: min(Self.pageSize, target - collected.count))
                guard generation == self.generation else { return }
                guard let page, page.rowCount > 0 else { break }
                let width = max(page.columnCount, 1)
                for row in 0..<page.rowCount {
                    let start = row * width
                    collected.append(Array(page.cells[start..<min(start + width, page.cells.count)]))
                }
            }
            guard generation == self.generation else { return }
            commit(collected, requested: target)
            await cursor.close()
            self.cursor = nil
        } catch {
            guard generation == self.generation else { return }
            report(error)
        }
        guard generation == self.generation else { return }
        isLoading = false
        isLoadingMore = false
        stopTiming()
        storePreviewIfReady()
    }

    /// Replace the grid's rows with the window that was just read.
    private func commit(_ cells: [[String?]], requested: Int) {
        rows = cells.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }
        rowsAreStale = false
        // Fewer rows than asked for means the result really is exhausted; the
        // limit is what stopped it otherwise.
        reachedEnd = cells.count < requested
        if let totalRowCount, rows.count >= totalRowCount { reachedEnd = true }
        if !reachedEnd, windowSize >= rowCap { hitRowCap = true }
    }

    /// DESCRIBE for the current source, if its schema isn't already known.
    private func startSchemaLoad(generation: Int) {
        guard case .source(let source) = mode else { return }
        if loadedSource == source, !columns.isEmpty { return }

        schemaTask = Task { [weak self] in
            guard let self else { return }
            do {
                let described = try await self.probe.columns(of: source)
                guard generation == self.generation, !described.isEmpty else { return }
                self.columns = described
                self.loadedSource = source
                self.storePreviewIfReady()
            } catch {
                // The preview may be perfectly fine without types — alignment
                // and filter widgets degrade, the rows do not. If the file is
                // genuinely unreadable the cursor reports it.
            }
        }
    }

    /// Called by the grid as it approaches the end of the loaded rows.
    public func loadMoreIfNeeded(displayedIndex: Int) {
        // Deliberately not `isBusy`: a `count(*)` over a huge dataset can run
        // for a while, and scrolling should not wait on it.
        guard !isLoading, !isLoadingMore, !reachedEnd, !hitRowCap else { return }
        guard displayedIndex >= rows.count - Self.prefetchDistance else { return }
        loadMore()
    }

    /// Widen the window and re-run.
    ///
    /// Doubling, not stepping: each widening is a fresh query, so a fixed step
    /// would mean a re-run per 500 rows. Doubling bounds the number of re-runs
    /// to reach any depth and keeps the rows transferred to roughly twice the
    /// window you end up with.
    public func loadMore() {
        guard !isLoading, !isLoadingMore, !reachedEnd else { return }
        let widened = min(windowSize * 2, rowCap)
        guard widened > windowSize else {
            hitRowCap = true
            return
        }
        windowSize = widened
        runQuery(keepingRows: true, widening: true)
    }

    /// Continue past the loaded-row cap at the user's request.
    public func continuePastCap() {
        guard hitRowCap else { return }
        rowCap *= 2
        hitRowCap = false
        loadMore()
    }

    private func report(_ error: Error) {
        if let duckError = error as? DuckDBError, duckError.isCancellation {
            // Expected whenever the user moves on mid-query.
            return
        }
        // A query that failed replaced nothing, so stale rows would now be
        // labelled by an error about a result that never arrived.
        if rowsAreStale {
            rows = []
            rowsAreStale = false
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func stopTiming() {
        guard let started = queryStartedAt else { return }
        lastQueryDuration = Date().timeIntervalSince(started)
        queryStartedAt = nil
    }

    /// Total matching rows, counted alongside the first page so the status bar
    /// can say "500 of 12,480,913 rows" rather than only what happens to be
    /// loaded. Runs for SQL results too, not just file selections.
    ///
    /// This is a separate `count(*)` on the metadata session rather than
    /// something derived from the grid's cursor — the whole point is to report
    /// rows that have *not* been fetched. On parquet it is answered largely from
    /// file metadata, so it is cheap even when the file is far too big to load.
    /// It runs concurrently with the preview, so a slow count over a large
    /// dataset never delays the rows.
    private func startRowCount(generation: Int) {
        let countQuery: BoundSQL
        switch mode {
        case .empty:
            isCountingRows = false
            return
        case .source(let source):
            countQuery = SQLBuilder.rowCount(source: source, filters: filters)
        case .sql(let text):
            countQuery = SQLBuilder.rowCount(rawSQL: text)
        }

        isCountingRows = true
        countTask = Task { [weak self] in
            guard let self else { return }
            // A count can legitimately fail (a non-SELECT statement in the SQL
            // editor, say). That is not worth an error banner — the status bar
            // simply falls back to reporting what is loaded.
            let count = try? await self.counter.count(countQuery)
            guard generation == self.generation else { return }
            self.totalRowCount = count
            self.isCountingRows = false
            if let count, self.rows.count >= count, !self.rowsAreStale { self.reachedEnd = true }
            self.storePreviewIfReady()
        }
    }

    // MARK: - Cache

    /// The fingerprint this result may be filed under, or nil when it must not
    /// be cached at all.
    ///
    /// Only a plain file or dataset view qualifies. A filtered, sorted or
    /// SQL-driven result is deliberately excluded: those are the answers a user
    /// is actively composing, where serving a remembered one would be
    /// indistinguishable from a fresh one and wrong in a way they could not see.
    private func fingerprintForCaching() async -> SourceFingerprint? {
        guard case .source(let source) = mode, filters.isEmpty, sort.isEmpty,
              windowSize == Self.pageSize
        else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SourceFingerprint.compute(for: source)
        }.value
    }

    private func apply(_ cached: CachedPreview, generation: Int) {
        columns = cached.columns
        if case .source(let source) = mode { loadedSource = source }
        rows = cached.rows.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }
        rowsAreStale = false
        totalRowCount = cached.totalRowCount
        isCountingRows = false
        reachedEnd = cached.reachedEnd
        isLoading = false
        servedFromCache = true
        // Nothing was queried. Scrolling past the remembered window widens it
        // and reads for real, the same as any other widening.
        stopTiming()
    }

    /// File the opening view once it is complete — page, schema and count.
    private func storePreviewIfReady() {
        guard let key = pendingCacheKey,
              !isLoading, !isCountingRows,
              case .source = mode, filters.isEmpty, sort.isEmpty,
              windowSize == Self.pageSize,
              errorMessage == nil,
              !columns.isEmpty, !rows.isEmpty
        else { return }

        pendingCacheKey = nil
        cache.store(
            CachedPreview(
                columns: columns,
                rows: rows.map(\.cells),
                totalRowCount: totalRowCount,
                reachedEnd: reachedEnd
            ),
            for: key
        )
    }

    /// Forget every remembered preview and re-read what is on screen.
    public func clearCache() {
        cache.clear()
        if case .source = mode { reload(keepingRows: true) }
    }
}
