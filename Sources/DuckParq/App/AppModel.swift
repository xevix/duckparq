import AppKit
import DuckParqCore
import Foundation
import UniformTypeIdentifiers

/// Top-level app state: which folders are in the sidebar, what's selected, and
/// which panels are open.
///
/// Each concern gets its own DuckDB session so they can't block or cancel one
/// another — a slow sort in the grid must not delay the schema panel, and
/// running SQL must not disturb an export in progress.
@MainActor
@Observable
final class AppModel {
    private enum Defaults {
        static let roots = "dev.xevix.duckparq.roots"
        static let formatOnSave = "dev.xevix.duckparq.formatOnSave"
        static let recentlyOpened = "dev.xevix.duckparq.recentlyOpened"
        static let expandedFolders = "dev.xevix.duckparq.expandedFolders"
        static let showsRecentlyOpened = "dev.xevix.duckparq.showsRecentlyOpened"
    }

    let engine: DuckDBEngine
    let table: TableModel
    let metaSession: DuckDBSession
    let countSession: DuckDBSession
    let inspectorSession: DuckDBSession
    let filterSession: DuckDBSession
    let sqlSession: DuckDBSession
    let exportSession: DuckDBSession
    let probe: Probe

    var roots: [URL] = [] {
        didSet {
            persistRoots()
            watchRoots()
        }
    }
    var selection: FileNode?
    /// The id of the highlighted row in the grid, if any.
    ///
    /// Here rather than in the grid's own `@State` because it is what the arrow
    /// keys mean: with a row selected they step through the rows, and with
    /// nothing selected they scroll. Clicking an empty part of the sidebar is
    /// how you get back to the second of those, and the sidebar cannot reach
    /// state that lives inside the grid.
    var selectedGridRow: Int?
    /// Changes whenever the grid should take the keyboard back.
    ///
    /// A nonce rather than a flag, for the reason `revealNonce` is one: asking
    /// twice has to count twice. The second click on an empty part of the
    /// sidebar hands the keyboard over exactly as the first did, and a flag that
    /// was already true would say nothing had happened.
    private(set) var gridFocusNonce = 0
    var searchQuery: String = ""

    /// Folders the sidebar is showing the inside of. Held here rather than in
    /// each row's `@State` so Collapse All and Expand All have something to act
    /// on — per-row state is invisible to anything but that row.
    ///
    /// Saved on every change, so quitting with a tree opened to the folder you
    /// were working in reopens to it — see `SidebarExpansion`, which owns the
    /// form it is saved in and the pruning it gets on the way back.
    var expandedFolders: Set<URL> = [] {
        didSet { persistExpansion() }
    }
    /// True while `expandAll()` is still walking the tree.
    private(set) var isExpandingAll = false

    /// Files opened from Finder that live outside every added folder.
    ///
    /// Opening a file is not a request to browse the folder it happens to sit
    /// in — that folder may be a Downloads directory with a thousand unrelated
    /// things in it. The file gets a row of its own instead, and adding the
    /// folder stays a deliberate act, on the row's context menu.
    private(set) var recentlyOpened: [URL] = [] {
        didSet { persistRecentlyOpened() }
    }
    /// Whether the Recently Opened section is showing its rows. Saved for the
    /// same reason the tree's folders are: Collapse All shuts it too, and a
    /// section that reopened itself on every launch would not stay shut.
    var showsRecentlyOpened = true {
        didSet {
            UserDefaults.standard.set(showsRecentlyOpened, forKey: Defaults.showsRecentlyOpened)
        }
    }

    private static let recentlyOpenedLimit = 20

    /// The route the sidebar has to scroll along to bring a row into view: the
    /// added folder, each folder below it, and last the file itself.
    ///
    /// A route rather than a destination because the sidebar builds rows only
    /// as they approach the viewport. A file a hundred folders down does not
    /// exist to be scrolled to until every folder above it has been scrolled to
    /// first — see `SidebarView`'s walk of this.
    private(set) var revealRoute: [URL] = []
    /// Changes on every request, so asking twice for the same row still counts
    /// as a change worth acting on.
    private(set) var revealNonce = 0

    /// Every folder the sidebar has read, and where its rows live.
    let listings = DirectoryListings()

    /// Watches the added folders, so the rows keep up with the disk.
    ///
    /// Created on the first root rather than in `init`, because watching nothing
    /// costs an FSEvents stream for no reason — and a fresh install has no
    /// folders at all.
    private var watcher: DirectoryWatcher?

    var showsInspector = false
    var showsSQLEditor = false
    var showsExportSheet = false

    var sqlText: String = ""
    var sqlError: String?
    /// Run the formatter over the editor before writing a `.sql` file.
    var formatsOnSave: Bool {
        didSet { UserDefaults.standard.set(formatsOnSave, forKey: Defaults.formatOnSave) }
    }
    /// Queries in the library directory, refreshed when the menu needs them.
    var savedQueries: [SavedQuery] = []
    /// Name of the `.sql` file currently loaded, shown in the editor header.
    var loadedQueryName: String?

    /// True once DuckDB's own keyword list has replaced the bootstrap one, so
    /// the editor re-highlights against the full set.
    private(set) var sqlKeywordsLoaded = false

    /// The text last written into the editor by the app rather than the user.
    /// Re-seeding only overwrites this, never something typed.
    private var seededSQL: String?
    /// Creation of the `t` view, awaited before running SQL that may use it.
    private var sqlContextTask: Task<Void, Never>?

    /// Held for the app's lifetime to keep macOS from putting DuckParq to sleep
    /// while it is in the background.
    ///
    /// App Nap throttles a fully occluded app's timers and drops its threads to
    /// background QoS; coming back from that is a plausible part of the pause on
    /// ⌘-Tab into a window that has been sitting behind others. `idleSystemSleep`
    /// is still allowed — this asks not to be throttled, not to keep the Mac
    /// awake.
    private var backgroundActivity: NSObjectProtocol?

    init() {
        // DuckDB is statically linked and opened in memory, with no files or
        // network involved -- if this fails the binary itself is broken, so
        // there is no meaningful degraded mode to fall back to.
        let engine = DuckDBEngine.shared
        self.engine = engine

        let gridSession = try! DuckDBSession(engine: engine, label: "grid")
        // A session is a serial queue, so "its own session" is the only way one
        // concern avoids waiting on another. The inspector and the row counter
        // each get one because both can run for seconds on a large dataset, and
        // neither should be able to hold up a schema lookup or each other.
        self.metaSession = try! DuckDBSession(engine: engine, label: "meta")
        self.countSession = try! DuckDBSession(engine: engine, label: "count")
        self.inspectorSession = try! DuckDBSession(engine: engine, label: "inspector")
        self.filterSession = try! DuckDBSession(engine: engine, label: "filter")
        self.sqlSession = try! DuckDBSession(engine: engine, label: "sql")
        self.exportSession = try! DuckDBSession(engine: engine, label: "export")
        self.probe = Probe(session: inspectorSession)
        self.table = TableModel(
            gridSession: gridSession,
            metaSession: metaSession,
            countSession: countSession,
            filterSession: filterSession
        )
        self.formatsOnSave = UserDefaults.standard.bool(forKey: Defaults.formatOnSave)

        self.backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeping browsed files and query state warm between activations"
        )

        loadRoots()
        // After the roots, which are what an expanded folder has to be found
        // under before it is worth restoring.
        loadExpansion()
        loadRecentlyOpened()
        refreshSavedQueries()

        // Syntax highlighting keywords come from the engine rather than a
        // hardcoded list — see SQLKeywords.
        let keywordSession = metaSession
        Task { @MainActor [weak self] in
            let loaded = await SQLKeywords.shared.load(using: keywordSession)
            self?.sqlKeywordsLoaded = loaded
        }
    }

    var duckdbVersion: String { engine.duckdbVersion }

    // MARK: - Roots

    private func loadRoots() {
        let paths = UserDefaults.standard.stringArray(forKey: Defaults.roots) ?? []
        roots = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persistRoots() {
        UserDefaults.standard.set(roots.map(\.path), forKey: Defaults.roots)
    }

    /// Point the watcher at the current set of folders.
    ///
    /// Called for every write to `roots`, including the ones that only reorder
    /// them; `DirectoryWatcher.watch` recognises an unchanged set and leaves its
    /// stream running, which is what keeps events from being lost across a
    /// change that was not about the folders at all.
    private func watchRoots() {
        if watcher == nil, !roots.isEmpty {
            watcher = DirectoryWatcher { [weak self] changes in
                // FSEvents answers on its own queue; the rows it is about are
                // main-actor state.
                Task { @MainActor in
                    guard let self else { return }
                    self.listings.directoriesDidChange(changes, in: self.roots)
                }
            }
        }
        watcher?.watch(roots)
    }

    /// The app is not sandboxed, so a plain path is enough to keep access —
    /// no security-scoped bookmarks needed.
    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to browse for parquet files"
        guard panel.runModal() == .OK else { return }
        addRoots(panel.urls)
    }

    /// Put folders in the sidebar, expanded, skipping any already there.
    ///
    /// Compared by path rather than by URL: the same folder arrives as `/a/b`
    /// from an open panel and `/a/b/` from a drop, and those two URLs are not
    /// equal — added twice, the sidebar would draw the folder twice.
    func addRoots(_ urls: [URL]) {
        for url in urls where !roots.contains(where: { $0.path == url.path }) {
            roots.append(url)
            expandedFolders.insert(url)
        }
    }

    // MARK: - Opening a file

    /// Choose a parquet file in a panel and open it.
    ///
    /// Deliberately the same call as a double-click in Finder, down to leaving
    /// the containing folder out of the sidebar: picking one file to look at is
    /// the same intent however it was picked, and having the two routes differ
    /// would only mean learning which is which.
    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Parquet has no system type, so this resolves through the extensions
        // the bundle declares — one type covering all three where the bundle is
        // registered, one per extension where it is not, hence the dedupe. An
        // empty list filters nothing, which is the right way to fail here:
        // showing every file beats showing none.
        var types: [UTType] = []
        for suffix in FileTree.parquetExtensions.sorted() {
            if let type = UTType(filenameExtension: suffix), !types.contains(type) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types
        panel.prompt = "Open"
        panel.message = "Choose a parquet file to open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Take what was dropped on the window.
    ///
    /// Returns whether the drop held anything DuckParq deals in. Saying no is
    /// what makes the dragged item fly back to where it came from, rather than
    /// disappearing into a window that quietly did nothing with it.
    ///
    /// A drop can carry a whole Finder selection, so both kinds are handled and
    /// each keeps the meaning it has everywhere else in the app:
    ///
    ///   - Folders go into the sidebar, exactly as Add Folder… puts them there.
    ///     Every folder dropped is added — the panel takes several at once too,
    ///     and a folder costs a row rather than the window's one table.
    ///   - Files: the first parquet file is opened. A window shows one table,
    ///     and picking the first is at least a rule that can be predicted.
    ///
    /// Folders first, so a drop of a folder and a file inside it opens the file
    /// in the tree it now belongs to rather than into Recently Opened.
    ///
    /// A folder already in the sidebar counts as accepted rather than refused:
    /// the drop was understood, and there is nothing left to do about it. Flying
    /// it back would say the folder is not there when it plainly is.
    @discardableResult
    func openDropped(_ urls: [URL]) -> Bool {
        let folders = FileTree.directories(in: urls)
        addRoots(folders)

        let file = FileTree.parquetFiles(in: urls).first
        if let file { open(file) }

        return !folders.isEmpty || file != nil
    }

    /// Open a parquet file, and put a row for it on screen.
    ///
    /// Shared by Finder and by Open File — see `openFile()`.
    ///
    /// Two cases, and the difference is whether the file is already reachable
    /// in the sidebar. Under an added folder, the chain of folders down to it
    /// is opened and the row scrolled to — the file was always there, it was
    /// just shut away. Outside every added folder it goes to Recently Opened,
    /// because silently adding its parent would drag a whole directory into the
    /// sidebar on the strength of one double-click.
    ///
    /// Either way the file opens in the grid; the row is about being able to
    /// find it again.
    func open(_ url: URL) {
        // A filtered sidebar is showing search results, not the tree, so
        // nothing can be revealed in it until the filter is gone.
        searchQuery = ""

        if let root = FileTree.root(containing: url, in: roots) {
            let folders = FileTree.ancestors(of: url, upTo: root)
            expandedFolders.formUnion(folders)
            requestReveal(along: folders + [url])
        } else {
            rememberRecentlyOpened(url)
            // A Recently Opened row sits at the top of the sidebar and is drawn
            // as soon as the section is, so there is nothing to walk down to.
            requestReveal(along: [url])
        }

        select(FileNode.file(at: url))
    }

    // MARK: - Recently opened

    private func loadRecentlyOpened() {
        let paths = UserDefaults.standard.stringArray(forKey: Defaults.recentlyOpened) ?? []
        recentlyOpened = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persistRecentlyOpened() {
        UserDefaults.standard.set(recentlyOpened.map(\.path), forKey: Defaults.recentlyOpened)
    }

    private func rememberRecentlyOpened(_ url: URL) {
        recentlyOpened.removeAll { $0.path == url.path }
        recentlyOpened.insert(url, at: 0)
        if recentlyOpened.count > Self.recentlyOpenedLimit {
            recentlyOpened.removeLast(recentlyOpened.count - Self.recentlyOpenedLimit)
        }
        showsRecentlyOpened = true
    }

    /// What Recently Opened actually draws.
    ///
    /// Filtered rather than pruned on the way in: a file whose folder gets
    /// added later belongs in the tree, and taking the row away is how you see
    /// that it moved there. Removing the folder again brings it back.
    var recentlyOpenedRows: [FileNode] {
        recentlyOpened
            .filter { !isCoveredByRoot($0) }
            .map(FileNode.file(at:))
    }

    func forgetRecentlyOpened(_ url: URL) {
        recentlyOpened.removeAll { $0.path == url.path }
    }

    func clearRecentlyOpened() {
        recentlyOpened = []
    }

    /// Whether the sidebar's tree can already reach this file.
    func isCoveredByRoot(_ url: URL) -> Bool {
        FileTree.root(containing: url, in: roots) != nil
    }

    /// Add the folder a file sits in, then reveal the file inside it.
    ///
    /// The row leaves Recently Opened as a consequence of the folder being
    /// added, not as a separate step — `recentlyOpenedRows` stops listing what
    /// the tree now shows.
    func addContainingFolder(of url: URL) {
        let folder = url.deletingLastPathComponent()
        if !roots.contains(where: { $0.path == folder.path }) {
            roots.append(folder)
        }
        expandedFolders.insert(folder)
        requestReveal(along: [folder, url])
    }

    // MARK: - Revealing a row

    /// Ask the sidebar to scroll along a route, ending on the row to show.
    private func requestReveal(along route: [URL]) {
        revealRoute = route
        revealNonce += 1
    }

    /// Whether a folder's rows exist to be scrolled to.
    func isDirectoryListed(_ url: URL) -> Bool {
        listings.isLoaded(url)
    }

    // MARK: - Sidebar expansion

    /// Put the tree back the way it was left.
    ///
    /// Nothing saved means a first launch — or an upgrade from a build that did
    /// not remember — and there the old rule still applies: a folder in the
    /// sidebar shows its contents, while nested folders stay shut until asked
    /// for, which is what keeps adding a big tree instant.
    ///
    /// An *empty* saved list is not that: it is a tree somebody collapsed, and
    /// it has to survive the quit, so the two are told apart by whether the key
    /// is there at all.
    private func loadExpansion() {
        let defaults = UserDefaults.standard
        if let paths = defaults.stringArray(forKey: Defaults.expandedFolders) {
            expandedFolders = SidebarExpansion.decoded(paths, under: roots)
        } else {
            expandedFolders = Set(roots)
        }
        if let saved = defaults.object(forKey: Defaults.showsRecentlyOpened) as? Bool {
            showsRecentlyOpened = saved
        }
    }

    private func persistExpansion() {
        UserDefaults.standard.set(
            SidebarExpansion.encoded(expandedFolders), forKey: Defaults.expandedFolders
        )
    }

    func isExpanded(_ url: URL) -> Bool { expandedFolders.contains(url) }

    func setExpanded(_ url: URL, _ expanded: Bool) {
        if expanded { expandedFolders.insert(url) } else { expandedFolders.remove(url) }
    }

    func toggleExpanded(_ url: URL) { setExpanded(url, !isExpanded(url)) }

    func collapseAll() {
        expandedFolders = []
        showsRecentlyOpened = false
    }

    /// Whether Collapse All has anything left to shut.
    var canCollapseAll: Bool {
        !expandedFolders.isEmpty || (showsRecentlyOpened && !recentlyOpenedRows.isEmpty)
    }

    /// Open every folder under every root.
    ///
    /// This is the one place the sidebar reads the whole tree rather than one
    /// level at a time, so it is bounded and runs off the main actor. Hive
    /// partitions are skipped: `FileTree` does not list them as folders, so
    /// expanding into them would only produce rows that cannot be drawn.
    func expandAll(limit: Int = 5_000) {
        guard !isExpandingAll else { return }
        isExpandingAll = true
        showsRecentlyOpened = true
        let roots = self.roots
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> Set<URL> in
                var expanded = Set(roots)
                var queue = roots
                while !queue.isEmpty, expanded.count < limit {
                    let directory = queue.removeFirst()
                    for node in FileTree.children(of: directory) where node.isDirectory {
                        expanded.insert(node.url)
                        queue.append(node.url)
                    }
                }
                return expanded
            }.value
            guard let self else { return }
            self.expandedFolders.formUnion(found)
            self.isExpandingAll = false
        }
    }

    /// Re-present an open panel for a folder macOS refused to list.
    ///
    /// The app is unsandboxed, but Downloads, Desktop and Documents are still
    /// TCC-protected. Choosing the folder in an open panel is what grants
    /// access — and because this build is ad-hoc signed, its identity changes on
    /// every rebuild, so a previously granted folder can start refusing again.
    @discardableResult
    func grantAccess(to url: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Grant Access"
        panel.message = "Select \(url.lastPathComponent) again to let DuckParq read it"
        return panel.runModal() == .OK
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        // The folders below it can no longer be drawn, so remembering them open
        // would only leave Collapse All lit with nothing to collapse — and would
        // keep saying so on every launch, since the set outlives the session now.
        expandedFolders = expandedFolders.filter { FileTree.chain(to: $0, under: url) == nil }
        listings.forget(under: url)
        if let selection, selection.url.path.hasPrefix(url.path) {
            self.selection = nil
            table.clear()
        }
    }

    // MARK: - Selection

    /// Let go of the grid's highlighted row and hand the grid the keyboard.
    ///
    /// Both halves, because one without the other is not what the click means.
    /// Dropping the row is what puts the arrows back to scrolling rather than
    /// stepping through rows; leaving the keyboard with the list that was
    /// clicked means the arrows do nothing at all, so the grid would be back in
    /// the state the click asked for and unable to show it.
    func releaseGridRow() {
        selectedGridRow = nil
        gridFocusNonce += 1
    }

    func select(_ node: FileNode) {
        // Clicking the row that is already selected changes nothing on screen,
        // so it should cost nothing: no re-read of the file, no scroll position
        // thrown away, no re-seeded editor. Compared by URL, which is what the
        // sidebar itself draws the selection highlight from.
        guard selection?.url != node.url else { return }
        guard let source = node.dataSource else { return }
        selection = node
        table.open(source)
        prepareSQLContext(for: source)
        // Following the selection matters more than preserving a stale query,
        // but only for text the user has not touched.
        if showsSQLEditor { seedSQLFromView() }
    }

    /// Expose the selection to the SQL editor as `t`, so a query can just say
    /// `FROM t` instead of repeating the read_parquet(...) call.
    ///
    /// See `SQLBuilder.createSourceView` for why this is a plain view with an
    /// inlined path. Both details were previously wrong in ways `try?` hid: the
    /// view was TEMP, so it was invisible on the connection that runs queries,
    /// and it was created with a bound parameter, which DuckDB refuses to
    /// prepare at all. `FROM t` therefore never worked.
    private func prepareSQLContext(for source: DataSource) {
        let statement = SQLBuilder.createSourceView(source)
        sqlContextTask?.cancel()
        sqlContextTask = Task { [sqlSession] in
            do {
                try await sqlSession.execute(statement)
            } catch {
                await MainActor.run { self.sqlError = error.localizedDescription }
            }
        }
    }

    var readExpressionForInsertion: String? {
        table.currentSource.map(SQLBuilder.readExpression(for:))
    }

    // MARK: - SQL editor

    func toggleSQLEditor() {
        showsSQLEditor.toggle()
        if showsSQLEditor { seedSQLFromView() }
    }

    /// Put the SQL behind the current view into the editor.
    ///
    /// Opening the editor over a selected file should show you what you are
    /// already looking at, expressed as a query you can change — that is the
    /// difference between a blank box and a starting point.
    ///
    /// Text the user typed is never overwritten. Only an empty editor, or one
    /// still holding exactly what was last seeded, gets replaced; `force` (the
    /// explicit "Load View SQL" button) overrides that, which is how you get
    /// back to the view's query after editing.
    func seedSQLFromView(force: Bool = false) {
        guard let text = table.editableSQL else { return }
        let current = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || current.isEmpty || current == seededSQL else { return }
        sqlText = text
        seededSQL = text
        loadedQueryName = nil
        sqlError = nil
    }

    /// True when the editor still holds the view's query, unedited.
    var sqlMatchesView: Bool {
        sqlText.trimmingCharacters(in: .whitespacesAndNewlines) == seededSQL
    }

    /// Re-indent the editor's contents.
    ///
    /// `SQLFormatter` only moves whitespace, so this cannot change what the
    /// query does — which is what makes it safe to offer next to a Run button.
    func formatSQL() {
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let formatted = SQLFormatter.format(sqlText)
        guard formatted != sqlText else { return }
        // Formatting untouched seeded text leaves it untouched in the sense that
        // matters: a filter change should still be free to replace it.
        let wasSeed = trimmed == seededSQL
        sqlText = formatted
        if wasSeed { seededSQL = formatted }
    }

    func runSQL() {
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sqlError = nil
        // `t` is created asynchronously on selection; a query typed straight
        // afterwards would otherwise race it and fail to resolve the name.
        Task { [sqlContextTask] in
            await sqlContextTask?.value
            table.runSQL(trimmed)
        }
    }

    func returnToFileView() {
        guard let selection, let source = selection.dataSource else {
            table.clear()
            return
        }
        table.open(source)
    }

    // MARK: - Saved queries

    func refreshSavedQueries() {
        savedQueries = QueryLibrary.saved()
    }

    /// Write the editor's contents to a `.sql` file.
    ///
    /// The save panel starts in the library directory but is not confined to
    /// it — a query is an ordinary file and belongs wherever the user wants it.
    func saveQuery() {
        guard !sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Formatting before the panel opens, not after it is dismissed, so what
        // gets written is what the editor is showing.
        if formatsOnSave { formatSQL() }
        let text = sqlText

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: QueryLibrary.fileExtension) ?? .plainText]
        panel.directoryURL = try? QueryLibrary.ensureDirectory()
        panel.nameFieldStringValue =
            (loadedQueryName as NSString?)?.deletingPathExtension
            ?? QueryLibrary.suggestedName(for: table.currentSource)
        panel.prompt = "Save Query"
        panel.message = "Save this query as a .sql file"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try QueryLibrary.save(text, to: url)
            loadedQueryName = url.lastPathComponent
            seededSQL = nil
            sqlError = nil
            refreshSavedQueries()
        } catch {
            sqlError = error.localizedDescription
        }
    }

    func openQuery() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: QueryLibrary.fileExtension) ?? .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = try? QueryLibrary.ensureDirectory()
        panel.prompt = "Open Query"
        panel.message = "Choose a .sql file to load into the editor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadQuery(from: url)
    }

    /// Load a `.sql` file into the editor — and stop there.
    ///
    /// Deliberately does not run it. A file's contents are shown before they
    /// execute, so a query from somewhere else is something you read first; and
    /// when it does run, it goes through the same read-only check as anything
    /// typed by hand.
    func loadQuery(from url: URL) {
        do {
            sqlText = try QueryLibrary.load(contentsOf: url)
            loadedQueryName = url.lastPathComponent
            seededSQL = nil
            sqlError = nil
            showsSQLEditor = true
        } catch {
            sqlError = error.localizedDescription
        }
    }

    // MARK: - Cache

    /// Forget every remembered preview.
    ///
    /// The cache keys on file size and modification time, which misses a rewrite
    /// that preserved both. This is the way out of that, and the reason it is a
    /// visible button rather than an internal detail.
    func clearCache() {
        table.clearCache()
    }
}
