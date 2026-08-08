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

    /// Bumped whenever `rows` is replaced by a different result.
    ///
    /// Row ids are ordinals, so a re-sort hands the grid the same ids carrying
    /// different cells. The grid needs to know that without comparing the cells
    /// themselves — on a two-thousand-column file that comparison is the diff,
    /// repeated for every row on screen. Comparing this instead makes it O(1).
    public private(set) var rowsGeneration = 0

    /// How many rows the last bump of `rowsGeneration` spliced onto the *front*
    /// of `rows`. Zero for every other kind of change.
    ///
    /// The grid holds its place with this. A scroll view keeps its offset when
    /// content is inserted above the viewport, so a prepend on its own moves
    /// the reader backward by the height of what arrived — and, if they had
    /// scrolled to the top of the window to ask for it, leaves them pinned
    /// against the top of the content with no further "up" left to scroll. That
    /// is what made the second page backward need a scroll *down* before it
    /// could be asked for again. Shifting the viewport by exactly this many
    /// rows keeps the rows under the eye still and leaves the newly loaded ones
    /// above to scroll up into.
    public private(set) var prependedRowCount = 0

    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    /// A backward step is in flight — `loadEarlier()`'s counterpart to
    /// `isLoadingMore`, kept separate so the grid can show a loading affordance
    /// at the top of the rows rather than the bottom.
    public private(set) var isLoadingEarlier = false
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

    /// Offset of `rows[0]` within the full result. Zero for the ordinary
    /// top-down window `commit()` fills in; only `jumpToEnd()` and
    /// `loadEarlier()` anchor it anywhere else.
    public private(set) var windowStart = 0

    /// The sort the current source opened in — see `defaultSort(for:)`.
    ///
    /// Kept so the preview cache can tell "the view as it opens" from "a view
    /// the user has sorted". Only the former is cacheable, and on a hive
    /// dataset the former is no longer the unsorted one.
    public private(set) var defaultSort: [SortKey] = []

    /// Whether the loaded rows already reach back to row 0 — nothing earlier
    /// to page in. The Home-key counterpart of `reachedEnd`.
    public var reachedStart: Bool { windowStart == 0 }

    private let gridSession: DuckDBSession
    /// Kept alongside `probe`, which wraps it, so the hive page index can read
    /// footers without queueing behind the grid's own reads.
    private let metaSession: DuckDBSession
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
    /// The current hive dataset's files in paging order, once read. Nil for
    /// anything that is not a hive dataset — see `pagesByFile`.
    private var hiveIndex: HivePageIndex?
    /// The source `hiveIndex` describes, so a different dataset does not get
    /// paged through the last one's file list.
    private var hiveIndexSource: DataSource?
    /// Bumped on every reload; results from an older generation are discarded.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    private var schemaTask: Task<Void, Never>?
    /// Distinct-value reads for filter autocompletion, by column name. Doubles
    /// as the memo for a completed one — see `valueIndex(for:in:)`.
    private var valueIndexTasks: [String: Task<DistinctValueIndex, Error>] = [:]

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
        self.metaSession = metaSession
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
        defaultSort = Self.defaultSort(for: source)
        sort = defaultSort
        discardValueIndexes()
        reload()
    }

    /// The sort a source opens in.
    ///
    /// Empty for a file, and for a plain folder of parquet files. A hive
    /// dataset opens ordered by its top-level partition key, which is the
    /// column it is physically laid out by — so the order is close to free,
    /// and having one is what lets the end of the dataset be read by turning
    /// the sort around instead of counting to it. See `fetchPage`.
    ///
    /// A default rather than a fixture: clicking the header clears it like any
    /// other sort, and `clearSort()` leaves the dataset unordered.
    private static func defaultSort(for source: DataSource) -> [SortKey] {
        guard case .dataset(let url) = source,
              let key = FileTree.topLevelHiveKey(of: url)
        else { return [] }
        return [SortKey(column: key, direction: .ascending)]
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
            self.defaultSort = []
            self.sort = []
            self.columns = []
            self.discardValueIndexes()
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
        defaultSort = []
        windowSize = Self.pageSize
        windowStart = 0
        prependedRowCount = 0
        rowCap = Self.loadedRowCap
        isLoading = false
        isLoadingMore = false
        isLoadingEarlier = false
        isCountingRows = false
        rowsAreStale = false
        queryStartedAt = nil
        discardValueIndexes()
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

    /// Completions for an equality filter being typed on `column`: the distinct
    /// values at or after what has been typed so far, in order.
    ///
    /// Answered from a held index of the column's values wherever it can be — a
    /// keystroke must not cost a read. DuckDB is asked directly only for a
    /// column with more distinct values than the index holds, and only once the
    /// typing has run past the end of what it holds, which is the one case
    /// where the local answer would be a short list passing itself off as the
    /// whole one.
    public func valueSuggestions(
        for column: ColumnInfo,
        startingAt typed: String,
        limit: Int = DistinctValueIndex.suggestionLimit
    ) async throws -> [String] {
        guard case .source(let source) = mode else { return [] }

        let index = try await valueIndex(for: column, in: source)
        let local = index.suggestions(startingAt: typed, limit: limit)
        if index.isComplete || local.count == limit { return local }

        return try await filterProbe.valueSuggestions(
            for: column, in: source, startingAt: typed, limit: limit
        )
    }

    /// The column's value index, read once and then remembered.
    ///
    /// The read is held as a task rather than awaited inline so that the next
    /// keystroke joins the one in flight instead of starting a second scan of
    /// the same column. Unstructured on purpose: the caller that started it is
    /// a view task that the following keystroke cancels, and that must not take
    /// the read everyone else is waiting on down with it.
    private func valueIndex(
        for column: ColumnInfo,
        in source: DataSource
    ) async throws -> DistinctValueIndex {
        if let existing = valueIndexTasks[column.name] { return try await existing.value }

        let cache = self.cache
        let probe = self.filterProbe
        let task = Task { () throws -> DistinctValueIndex in
            let fingerprint = await Task.detached(priority: .userInitiated) {
                SourceFingerprint.compute(for: source)
            }.value
            if let fingerprint, let cached = cache.valueIndex(for: fingerprint, column: column.name) {
                return cached
            }
            let index = try await probe.distinctValueIndex(for: column, in: source)
            if let fingerprint {
                cache.storeValueIndex(index, for: fingerprint, column: column.name)
            }
            return index
        }
        valueIndexTasks[column.name] = task

        do {
            return try await task.value
        } catch {
            // A failed read is not an answer worth remembering, so the next
            // keystroke gets to try again. Only if it is still the current one:
            // a retry may already have replaced it.
            if valueIndexTasks[column.name] == task { valueIndexTasks[column.name] = nil }
            throw error
        }
    }

    /// Value indexes belong to the source they were read from.
    private func discardValueIndexes() {
        for task in valueIndexTasks.values { task.cancel() }
        valueIndexTasks.removeAll()
    }

    // MARK: - Loading

    /// The query the grid is currently showing, for export and for the SQL
    /// editor's "edit this query" affordance.
    public var currentQuery: BoundSQL? { query(orderedBy: sort) }

    /// `currentQuery` with a different ORDER BY — the same source, filters and
    /// shape, ordered as asked. Only `jumpToEnd()` uses anything but `sort`.
    private func query(orderedBy order: [SortKey]) -> BoundSQL? {
        switch mode {
        case .empty:
            return nil
        case .source(let source):
            return SQLBuilder.rows(source: source, filters: filters, sort: order)
        case .sql(let text):
            return BoundSQL(sql: SQLBuilder.sorted(rawSQL: text, sort: order), params: [])
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
    public var isBusy: Bool { isLoading || isLoadingMore || isLoadingEarlier || isCountingRows }

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
        isLoadingEarlier = false
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
        // The file list survives a reload — the files did not move — but how
        // many rows of each one a filter admits does not.
        hiveIndex?.invalidateCounts()
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
        isLoadingEarlier = false
        wasCancelled = false
        // Every full re-run — first look or widened window alike — starts
        // counting from row 0. Only `jumpToEnd()`/`loadEarlier()` move this.
        if !widening { windowStart = 0 }
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

    // MARK: - Paging a hive dataset by file

    /// Whether the grid is paging by walking the dataset's files in order
    /// rather than by `ORDER BY` and `OFFSET`.
    ///
    /// True for a hive dataset still in the partition order it opened in.
    /// `ORDER BY <partition key>` does not name a particular row — a partition
    /// key is the thing the dataset is divided by, so under it nearly every row
    /// ties with nearly every other, and two pages read at two offsets are two
    /// executions free to break those ties differently. Walking the files
    /// instead gives an order that is fixed by the paths and the scan, so
    /// adjacent pages cannot disagree. See `HivePageIndex`.
    ///
    /// A user sort takes it back to `ORDER BY`: the file order says nothing
    /// about a column that is not the partition key.
    public var pagesByFile: Bool {
        hiveIndex != nil && !defaultSort.isEmpty && sort == defaultSort
    }

    /// Read the current dataset's file list, unless it is already in hand.
    ///
    /// Footers only — no column data is touched, which is what makes it cheap
    /// enough to do before the first page rather than alongside it. On its own
    /// session, so it does not queue behind the grid's own reads.
    private func ensureHiveIndex() async {
        guard case .source(let source) = mode, case .dataset(let url) = source else {
            hiveIndex = nil
            hiveIndexSource = nil
            return
        }
        if hiveIndexSource == source { return }
        guard FileTree.topLevelHiveKey(of: url) != nil else {
            // A plain folder of parquet files has no partition order to walk.
            hiveIndex = nil
            hiveIndexSource = source
            return
        }
        hiveIndex = try? await HivePageIndex.build(source: source, session: metaSession)
        hiveIndexSource = source
    }

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

        await ensureHiveIndex()
        guard generation == self.generation else { return }

        let target = windowSize
        do {
            // A hive dataset in its opening order is paged by walking its
            // files, which needs no cursor and no ORDER BY: the file list is
            // the order. Every other result still streams from a cursor.
            if pagesByFile, let index = hiveIndex {
                let page = try await index.read(
                    start: 0, count: target, filters: filters, columnCount: columns.count
                )
                guard generation == self.generation else { return }
                if columns.isEmpty {
                    columns = page.columns.map { ColumnInfo(name: $0, typeName: "VARCHAR") }
                }
                commit(page.rows, requested: target)
            } else {
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
                // one stitched onto part of the old, and no row can appear twice
                // in what is on screen.
                //
                // That is as far as it goes, and less far than it used to claim.
                // One query cannot repeat a row, but two do not have to agree:
                // where the sort has ties, widening from 500 to 1000 rows can
                // come back with a different 500 in front, so rows the reader
                // has already passed are silently swapped out. Measured on the
                // hive fixture at all 500 rows replaced, in two runs out of five.
                // A hive dataset in its opening order no longer comes through
                // here; anything else still needs a tiebreaker in the ORDER BY
                // to be free of it.
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
            }
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
        rowsGeneration += 1
        prependedRowCount = 0
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

    /// Called by the grid as a row appears near the end of the loaded rows.
    ///
    /// Forward only, and deliberately so. A row appearing says nothing about
    /// where the user is: a `LazyVStack` fills from the top, so the rows it
    /// realises the instant a window lands are the ones at `windowStart`
    /// whether or not anyone scrolled there. Reading that as "the user is at
    /// the top, page in what comes before it" is what made a jump to the end
    /// immediately load a second page behind itself. Going backward is
    /// therefore not reachable from here at all — it is `loadEarlier()`, which
    /// the grid calls only from an actual upward scroll.
    ///
    /// `displayedIndex` is the row's `id` — a global offset into the full
    /// result, not a position in `rows` — so it is compared against
    /// `windowStart` rather than assumed to start at 0.
    public func loadMoreIfNeeded(displayedIndex: Int) {
        // Deliberately not `isBusy`: a `count(*)` over a huge dataset can run
        // for a while, and scrolling should not wait on it.
        guard !isLoading, !isLoadingMore, !isLoadingEarlier else { return }
        guard !reachedEnd, !hitRowCap else { return }
        let localIndex = displayedIndex - windowStart
        guard localIndex >= rows.count - Self.prefetchDistance else { return }
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
        windowStart == 0 ? loadMore() : loadEarlier()
    }

    /// Extend the window backward by one page, the way scrolling up past
    /// `windowStart` should page in earlier rows — the mirror of `loadMore()`
    /// widening it forward.
    ///
    /// A constant step, not a doubling one: `loadMore()` doubles because each
    /// widening is a fresh `LIMIT`-from-0 re-run, so doubling bounds the number
    /// of re-runs needed to reach any depth. A backward step is a plain
    /// `OFFSET` read of rows not yet loaded — there is no re-run to amortize,
    /// so there is nothing a bigger step would buy beyond a larger single read.
    public func loadEarlier() {
        guard !isLoading, !isLoadingMore, !isLoadingEarlier else { return }
        guard windowStart > 0, !isExplain else { return }
        guard rows.count < rowCap else {
            hitRowCap = true
            return
        }
        guard currentQuery != nil else { return }

        let chunk = min(Self.pageSize, windowStart)
        let start = windowStart - chunk

        generation += 1
        let generation = self.generation
        cancelInFlight()
        isLoadingEarlier = true
        wasCancelled = false
        queryStartedAt = Date()
        lastQueryDuration = nil

        loadTask = Task { [weak self] in
            await self?.performEarlierLoad(start: start, limit: chunk, generation: generation)
        }
    }

    private func performEarlierLoad(start: Int, limit: Int, generation: Int) async {
        do {
            // Stepping back from a window anchored at the end, this is the
            // page just inside the one already loaded — offset 500 from the
            // far end, then 1000, rather than three billion from the near one.
            let page = try await fetchPage(start: start, count: limit, total: totalRowCount)
            guard generation == self.generation else { return }
            prepend(page, start: start)
        } catch {
            guard generation == self.generation else { return }
            report(error)
        }
        guard generation == self.generation else { return }
        isLoadingEarlier = false
        stopTiming()
    }

    /// Splice an earlier page onto the front of the loaded rows. The backward
    /// counterpart of `commit()` — `reachedEnd` is left alone, since nothing
    /// about the tail changed.
    private func prepend(_ cells: [[String?]], start: Int) {
        guard !cells.isEmpty else { return }
        let earlier = cells.enumerated().map { GridRow(id: start + $0.offset, cells: $0.element) }
        rows = earlier + rows
        rowsGeneration += 1
        prependedRowCount = earlier.count
        windowStart = start
    }

    /// Load the window at the end of the result and anchor there — what the
    /// Home key's opposite number, the End key, asks for: the last page, not
    /// the whole file.
    ///
    /// Needs the total row count to know where that page starts, so this waits
    /// for the count to resolve if it has not already — the one place loading
    /// the last page has to be slower than loading the first, which never
    /// needs to know how much comes after it.
    public func jumpToEnd() {
        guard currentQuery != nil, !isExplain else { return }

        generation += 1
        let generation = self.generation
        cancelInFlight()
        errorMessage = nil
        isLoading = true
        isLoadingMore = false
        isLoadingEarlier = false
        wasCancelled = false
        rowsAreStale = false
        reachedEnd = false
        queryStartedAt = Date()
        lastQueryDuration = nil

        loadTask = Task { [weak self] in
            await self?.performTailLoad(generation: generation)
        }
    }

    private func performTailLoad(generation: Int) async {
        if totalRowCount == nil, let countQuery = rowCountQuery() {
            isCountingRows = true
            let count = try? await counter.count(countQuery)
            guard generation == self.generation else { return }
            totalRowCount = count
            isCountingRows = false
        }

        guard let total = totalRowCount, currentQuery != nil else {
            isLoading = false
            stopTiming()
            return
        }
        guard total > 0 else {
            rows = []
            rowsGeneration += 1
            prependedRowCount = 0
            windowStart = 0
            reachedEnd = true
            isLoading = false
            stopTiming()
            return
        }

        let start = max(0, total - Self.pageSize)
        let limit = total - start

        do {
            let page = try await fetchPage(start: start, count: limit, total: total)
            guard generation == self.generation else { return }
            commitTail(page, offset: start)
        } catch {
            guard generation == self.generation else { return }
            report(error)
        }
        guard generation == self.generation else { return }
        isLoading = false
        stopTiming()
    }

    /// Read the rows at `[start, start + count)` of the current result,
    /// counted from whichever end of it they are nearer to.
    ///
    /// Counting from the start to a page near the end means DuckDB producing
    /// and discarding everything in front of it — three billion rows for the
    /// last page of a dataset that size, and very nearly that again for the
    /// page before it. Turning the sort around counts the same page from the
    /// other end, where the last page is at offset 0, the one before it at
    /// 500, and so on back; the rows arrive reversed and are turned over here.
    /// The crossover is the midpoint, after which counting forward is the
    /// shorter way round again.
    ///
    /// Turning the sort around is also what stops `ORDER BY x … OFFSET n`
    /// being planned as a full sort. A Top-N cannot answer that shape — the
    /// rows it keeps are the ones the offset wants discarded — so DuckDB
    /// orders the whole result to reach the end of it. Inverted it is an
    /// ordinary Top-N: 5.58s against 0.26s at 100M rows.
    ///
    /// Both need a sort to invert. An unsorted result has no order to run
    /// backward — a scan's "last 500 rows" are defined by nothing but the scan
    /// — so those are counted forward however far in they are. That is the
    /// case a hive dataset sidesteps by opening ordered by its partition key.
    ///
    /// Where the sort has ties this can return a different page than counting
    /// forward would: both hold rows equal under the sort, but which of a tied
    /// group falls in a given page is not something `ORDER BY x` settles.
    private func fetchPage(start: Int, count: Int, total: Int?) async throws -> [[String?]] {
        await ensureHiveIndex()

        // A hive dataset in its opening order does not need either way round:
        // the file list already says which rows sit at `[start, start + count)`,
        // and says it the same way every time it is asked. Neither the ties nor
        // the crossover between counting forward and counting backward — the
        // two things the rest of this method has to trade off — arise at all.
        if pagesByFile, let index = hiveIndex {
            return try await index.read(
                start: start, count: count, filters: filters, columnCount: columns.count
            ).rows
        }

        let inverted = sort.map { SortKey(column: $0.column, direction: $0.direction.inverted) }
        let address = Self.pageAddress(
            start: start, count: count, total: total, invertible: !sort.isEmpty
        )

        let source: BoundSQL?
        let offset: Int
        switch address {
        case .forward(let forwardOffset):
            source = currentQuery
            offset = forwardOffset
        case .reversed(let reversedOffset):
            source = query(orderedBy: inverted)
            offset = reversedOffset
        }
        guard let source else { return [] }

        let bounded = SQLBuilder.windowed(source, limit: count, offset: offset)
        let batch = try await gridSession.queryAll(bounded.sql, params: bounded.params, limit: count)
        let page = cells(from: batch)
        if case .reversed = address { return page.reversed() }
        return page
    }

    /// Which end of the result a page is counted from.
    public enum PageAddress: Equatable, Sendable {
        /// Counted forward from the first row, in the sort as it stands.
        case forward(offset: Int)
        /// Counted back from the last row, with the sort inverted. The rows
        /// arrive in reverse and are turned over before they are shown.
        case reversed(offset: Int)
    }

    /// Pick the shorter way round to the page at `[start, start + count)`.
    ///
    /// Split out from `fetchPage` because it is the whole idea, and it is
    /// arithmetic: the last page of three billion rows is `.reversed(0)`, the
    /// page before it `.reversed(500)`, and somewhere around the midpoint
    /// counting forward becomes the shorter way again.
    ///
    /// `.forward` whenever there is no sort to invert, or no total to measure
    /// against — an unsorted result has no order to run backward.
    public static func pageAddress(
        start: Int, count: Int, total: Int?, invertible: Bool
    ) -> PageAddress {
        guard invertible, let total else { return .forward(offset: start) }
        let reversedOffset = total - (start + count)
        guard reversedOffset >= 0, reversedOffset < start else { return .forward(offset: start) }
        return .reversed(offset: reversedOffset)
    }

    /// Replace the grid's rows with a window anchored at the end of the
    /// result. Unlike `commit()`, `reachedEnd` does not need to be inferred
    /// from a short read — asking for exactly what is left past `offset` means
    /// whatever comes back already is the end.
    private func commitTail(_ cells: [[String?]], offset: Int) {
        rows = cells.enumerated().map { GridRow(id: offset + $0.offset, cells: $0.element) }
        rowsGeneration += 1
        prependedRowCount = 0
        rowsAreStale = false
        windowStart = offset
        windowSize = max(cells.count, Self.pageSize)
        reachedEnd = true
        hitRowCap = false
        // These rows are the end of the file, so they are not the opening
        // preview this load may have been on its way to filing.
        pendingCacheKey = nil
    }

    /// Return to the opening window — what the Home key asks for after the
    /// window has moved elsewhere. Reruns the query exactly as `reload()`
    /// does for a freshly opened file: one page from row 0, not everything
    /// paged in on the way there.
    public func jumpToStart() {
        guard windowStart != 0 else { return }
        reload()
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
        guard let countQuery = rowCountQuery() else {
            isCountingRows = false
            return
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

    /// The `count(*)` for the current mode, or nil when there is nothing to
    /// count against — shared by the count that runs alongside every fresh
    /// load and the one `jumpToEnd()` needs on demand.
    private func rowCountQuery() -> BoundSQL? {
        switch mode {
        case .empty:
            return nil
        case .source(let source):
            return SQLBuilder.rowCount(source: source, filters: filters)
        case .sql(let text):
            return SQLBuilder.rowCount(rawSQL: text)
        }
    }

    /// Row-major cells from a fully collected batch, in the same
    /// `[[String?]]` shape the streaming cursor path produces.
    private func cells(from batch: RowBatch) -> [[String?]] {
        let width = max(batch.columns.count, columns.count, 1)
        var result: [[String?]] = []
        result.reserveCapacity(batch.rowCount)
        for row in 0..<batch.rowCount {
            let start = row * width
            result.append(Array(batch.cells[start..<min(start + width, batch.cells.count)]))
        }
        return result
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
        guard case .source(let source) = mode, filters.isEmpty, sort == defaultSort,
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
        rowsGeneration += 1
        prependedRowCount = 0
        rowsAreStale = false
        windowStart = 0
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
              case .source = mode, filters.isEmpty, sort == defaultSort,
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
        discardValueIndexes()
        if case .source = mode { reload(keepingRows: true) }
    }
}
