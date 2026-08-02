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

    private let gridSession: DuckDBSession
    private let probe: Probe

    private var cursor: QueryCursor?
    /// Bumped on every reload; results from an older generation are discarded.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?

    public init(gridSession: DuckDBSession, metaSession: DuckDBSession) {
        self.gridSession = gridSession
        self.probe = Probe(session: metaSession)
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

    // MARK: - Actions

    public func open(_ source: DataSource) {
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
        reload()
    }

    public func clearSort() {
        guard !sort.isEmpty else { return }
        sort = []
        reload()
    }

    public func upsert(filter: Filter) {
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters[index] = filter
        } else {
            filters.append(filter)
        }
        reload()
    }

    public func removeFilter(id: Filter.ID) {
        guard filters.contains(where: { $0.id == id }) else { return }
        filters.removeAll { $0.id == id }
        reload()
    }

    public func clearFilters() {
        guard !filters.isEmpty else { return }
        filters = []
        reload()
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

    private func cancelInFlight() {
        loadTask?.cancel()
        loadTask = nil
        countTask?.cancel()
        countTask = nil
        // Stop the query that is actually running rather than letting it finish
        // into a result nobody will read.
        gridSession.interrupt()
        if let cursor {
            Task { await cursor.close() }
        }
        cursor = nil
    }

    public func reload() {
        generation += 1
        let generation = self.generation
        cancelInFlight()

        rows = []
        reachedEnd = false
        hitRowCap = false
        errorMessage = nil
        isLoading = true
        isLoadingMore = false

        guard let query = currentQuery else {
            isLoading = false
            return
        }

        loadTask = Task { [weak self] in
            await self?.performInitialLoad(query: query, generation: generation)
        }
        refreshRowCount(generation: generation)
    }

    private func performInitialLoad(query: BoundSQL, generation: Int) async {
        do {
            if case .source(let source) = mode, columns.isEmpty || !sameSource(source) {
                columns = try await probe.columns(of: source)
                loadedSource = source
            }
            guard generation == self.generation else { return }

            let cursor = try await gridSession.openCursor(query.sql, params: query.params)
            guard generation == self.generation else {
                await cursor.close()
                return
            }
            self.cursor = cursor

            // In SQL mode there is no DESCRIBE to lean on, so column identity
            // comes from the result itself. Types are unknown, hence VARCHAR.
            if case .sql = mode {
                columns = cursor.columnNames.map { ColumnInfo(name: $0, typeName: "VARCHAR") }
            }

            let page = try await cursor.fetch(maxRows: Self.pageSize)
            guard generation == self.generation else { return }
            append(page, cursor: cursor)
        } catch {
            guard generation == self.generation else { return }
            report(error)
        }
        if generation == self.generation { isLoading = false }
    }

    private var loadedSource: DataSource?

    private func sameSource(_ source: DataSource) -> Bool { loadedSource == source }

    /// Called by the grid as it approaches the end of the loaded rows.
    public func loadMoreIfNeeded(displayedIndex: Int) {
        guard !isLoading, !isLoadingMore, !reachedEnd, !hitRowCap, cursor != nil else { return }
        guard displayedIndex >= rows.count - Self.prefetchDistance else { return }
        loadMore()
    }

    public func loadMore() {
        guard !isLoadingMore, !reachedEnd, let cursor else { return }
        if rows.count >= Self.loadedRowCap {
            hitRowCap = true
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

    /// Continue past the loaded-row cap at the user's request.
    public func continuePastCap() {
        guard hitRowCap else { return }
        hitRowCap = false
        loadMore()
    }

    private func append(_ page: RowPage?, cursor: QueryCursor) {
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
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Total matching rows, counted alongside the first page so the status bar
    /// can say "500 of 12,480,913 rows" rather than only what happens to be
    /// loaded. Runs for SQL results too, not just file selections.
    ///
    /// This is a separate `count(*)` on the metadata session rather than
    /// something derived from the grid's cursor — the whole point is to report
    /// rows that have *not* been fetched. On parquet it is answered largely from
    /// file metadata, so it is cheap even when the file is far too big to load.
    private func refreshRowCount(generation: Int) {
        totalRowCount = nil

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
        }
    }
}
