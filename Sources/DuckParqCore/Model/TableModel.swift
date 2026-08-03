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

    /// Rows per fetch. Large enough that scrolling rarely waits, small enough
    /// that the first screenful appears promptly.
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

    private let gridSession: DuckDBSession
    private let probe: Probe
    private let cache: PreviewCache

    private var cursor: QueryCursor?
    /// Bumped on every reload; results from an older generation are discarded.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    private var schemaTask: Task<Void, Never>?

    /// The query whose cursor has not been opened yet, because the first page
    /// came from the cache. Opened if the user scrolls past it.
    private var deferredQuery: BoundSQL?
    /// Where to file this result once it has both a page and a count.
    private var pendingCacheKey: SourceFingerprint?
    private var loadedSource: DataSource?

    public init(
        gridSession: DuckDBSession,
        metaSession: DuckDBSession,
        cache: PreviewCache = .shared
    ) {
        self.gridSession = gridSession
        self.probe = Probe(session: metaSession)
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
            do {
                try await self.gridSession.validateReadOnly(trimmed)
            } catch {
                guard generation == self.generation else { return }
                self.isLoading = false
                self.report(error)
                return
            }
            guard generation == self.generation else { return }
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
        deferredQuery = nil
        pendingCacheKey = nil
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

    public func filterAffordance(for column: ColumnInfo) async throws -> FilterAffordance {
        guard case .source(let source) = mode else { return .comparison }
        return try await probe.filterAffordance(for: column, in: source)
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
        // Paging deliberately stops here rather than resuming on the next
        // scroll. Re-opening the stream would re-run the query the user just
        // stopped, and skip its way back to where they were to do it.
        deferredQuery = nil
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
        generation += 1
        let generation = self.generation
        cancelInFlight()

        if !keepingRows { rows = [] }
        rowsAreStale = keepingRows && !rows.isEmpty
        reachedEnd = false
        hitRowCap = false
        errorMessage = nil
        isLoading = true
        isLoadingMore = false
        wasCancelled = false
        servedFromCache = false
        deferredQuery = nil
        pendingCacheKey = nil
        totalRowCount = nil
        queryStartedAt = Date()
        lastQueryDuration = nil

        guard let query = currentQuery else {
            isLoading = false
            isCountingRows = false
            stopTiming()
            return
        }

        isCountingRows = true
        loadTask = Task { [weak self] in
            await self?.performInitialLoad(query: query, generation: generation)
        }
    }

    /// Rows on screen belong to the previous query and are replaced, not
    /// appended to, when the next page arrives.
    private var rowsAreStale = false

    private func performInitialLoad(query: BoundSQL, generation: Int) async {
        // A cache hit has to be settled before anything is issued, or the work
        // it is meant to avoid is already underway.
        if let key = await fingerprintForCaching() {
            guard generation == self.generation else { return }
            if let cached = cache.preview(for: key) {
                apply(cached, query: query, generation: generation)
                return
            }
            pendingCacheKey = key
        }
        guard generation == self.generation else { return }

        // Schema, preview and total row count are three independent questions.
        // They used to be asked in a chain, so a DESCRIBE across a thousand-file
        // dataset held up rows that DuckDB could already have streamed. Each now
        // renders the moment it can.
        startSchemaLoad(generation: generation)
        startRowCount(generation: generation)

        do {
            let cursor = try await gridSession.openCursor(query.sql, params: query.params)
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

            let page = try await cursor.fetch(maxRows: Self.pageSize)
            guard generation == self.generation else { return }
            append(page, cursor: cursor)
        } catch {
            guard generation == self.generation else { return }
            report(error)
        }
        guard generation == self.generation else { return }
        isLoading = false
        stopTiming()
        storePreviewIfReady()
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
        guard !isLoading, !isLoadingMore, !reachedEnd, !hitRowCap else { return }
        guard cursor != nil || deferredQuery != nil else { return }
        guard displayedIndex >= rows.count - Self.prefetchDistance else { return }
        loadMore()
    }

    public func loadMore() {
        guard !isLoadingMore, !reachedEnd else { return }
        if rows.count >= Self.loadedRowCap {
            hitRowCap = true
            return
        }
        guard let cursor else {
            openDeferredCursor()
            return
        }
        isLoadingMore = true
        let generation = self.generation

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await cursor.fetch(maxRows: Self.pageSize)
                guard generation == self.generation else { return }
                self.append(page, cursor: cursor)
            } catch {
                guard generation == self.generation else { return }
                self.report(error)
            }
            if generation == self.generation { self.isLoadingMore = false }
        }
    }

    /// Open the stream that a cache hit let us skip.
    ///
    /// The rows on screen came from memory, so no cursor exists yet. A stream
    /// always starts at the first row, so the cached page has to be read past
    /// before appending — one page of work, paid only if the user scrolls.
    private func openDeferredCursor() {
        guard let query = deferredQuery else { return }
        deferredQuery = nil
        isLoadingMore = true
        let generation = self.generation
        let alreadyShown = rows.count

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cursor = try await self.gridSession.openCursor(query.sql, params: query.params)
                guard generation == self.generation else {
                    await cursor.close()
                    return
                }
                self.cursor = cursor

                var skipped = 0
                var exhausted = false
                while skipped < alreadyShown {
                    let page = try await cursor.fetch(maxRows: min(Self.pageSize, alreadyShown - skipped))
                    guard generation == self.generation else { return }
                    guard let page, page.rowCount > 0 else {
                        exhausted = true
                        break
                    }
                    skipped += page.rowCount
                }

                if exhausted {
                    self.reachedEnd = true
                } else {
                    let page = try await cursor.fetch(maxRows: Self.pageSize)
                    guard generation == self.generation else { return }
                    self.append(page, cursor: cursor)
                }
            } catch {
                guard generation == self.generation else { return }
                self.report(error)
            }
            if generation == self.generation { self.isLoadingMore = false }
        }
    }

    /// Continue past the loaded-row cap at the user's request.
    public func continuePastCap() {
        guard hitRowCap else { return }
        hitRowCap = false
        loadMore()
    }

    private func append(_ page: RowPage?, cursor: QueryCursor) {
        if rowsAreStale {
            // The first page of the new query displaces the previous result in
            // one step, so the grid never shows a mixture of the two.
            rows = []
            rowsAreStale = false
        }
        guard let page, page.rowCount > 0 else {
            reachedEnd = true
            return
        }
        let width = max(page.columnCount, 1)
        var appended: [GridRow] = []
        appended.reserveCapacity(page.rowCount)
        for row in 0..<page.rowCount {
            let start = row * width
            let cells = Array(page.cells[start..<min(start + width, page.cells.count)])
            appended.append(GridRow(id: rows.count + row, cells: cells))
        }
        rows.append(contentsOf: appended)
        if page.rowCount < Self.pageSize { reachedEnd = true }
        // A stream only reveals it is finished when a fetch comes back empty,
        // which would leave the last full page looking like there is more to
        // come. When the total is known (and matches these filters), the end is
        // already provable — so say so now rather than after another round trip.
        if let totalRowCount, rows.count >= totalRowCount { reachedEnd = true }
        if rows.count >= Self.loadedRowCap { hitRowCap = true }
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
            let count = try? await self.probe.count(countQuery)
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
        guard case .source(let source) = mode, filters.isEmpty, sort.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SourceFingerprint.compute(for: source)
        }.value
    }

    private func apply(_ cached: CachedPreview, query: BoundSQL, generation: Int) {
        columns = cached.columns
        if case .source(let source) = mode { loadedSource = source }
        rows = cached.rows.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }
        rowsAreStale = false
        totalRowCount = cached.totalRowCount
        isCountingRows = false
        reachedEnd = cached.reachedEnd
        isLoading = false
        servedFromCache = true
        // Nothing has been queried, so there is no stream. One is opened only if
        // the user scrolls past what was remembered.
        deferredQuery = cached.reachedEnd ? nil : query
        stopTiming()
    }

    /// File the opening view once it is complete — page, schema and count.
    private func storePreviewIfReady() {
        guard let key = pendingCacheKey,
              !isLoading, !isCountingRows,
              case .source = mode, filters.isEmpty, sort.isEmpty,
              errorMessage == nil,
              !columns.isEmpty, !rows.isEmpty
        else { return }

        pendingCacheKey = nil
        let firstPage = rows.prefix(Self.pageSize).map(\.cells)
        cache.store(
            CachedPreview(
                columns: columns,
                rows: Array(firstPage),
                totalRowCount: totalRowCount,
                // `reachedEnd` describes everything loaded so far; it only says
                // something about the first page when that is all there is.
                reachedEnd: reachedEnd && rows.count <= Self.pageSize
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
