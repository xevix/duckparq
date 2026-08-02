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
    }

    let engine: DuckDBEngine
    let table: TableModel
    let metaSession: DuckDBSession
    let sqlSession: DuckDBSession
    let exportSession: DuckDBSession
    let probe: Probe

    var roots: [URL] = [] {
        didSet { persistRoots() }
    }
    var selection: FileNode?
    var searchQuery: String = ""

    var showsInspector = false
    var showsSQLEditor = false
    var showsExportSheet = false

    var sqlText: String = ""
    var sqlError: String?
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

    init() {
        // DuckDB is statically linked and opened in memory, with no files or
        // network involved -- if this fails the binary itself is broken, so
        // there is no meaningful degraded mode to fall back to.
        let engine = DuckDBEngine.shared
        self.engine = engine

        let gridSession = try! DuckDBSession(engine: engine, label: "grid")
        self.metaSession = try! DuckDBSession(engine: engine, label: "meta")
        self.sqlSession = try! DuckDBSession(engine: engine, label: "sql")
        self.exportSession = try! DuckDBSession(engine: engine, label: "export")
        self.probe = Probe(session: metaSession)
        self.table = TableModel(gridSession: gridSession, metaSession: metaSession)

        loadRoots()
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
        for url in panel.urls where !roots.contains(url) {
            roots.append(url)
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
        if let selection, selection.url.path.hasPrefix(url.path) {
            self.selection = nil
            table.clear()
        }
    }

    // MARK: - Selection

    func select(_ node: FileNode) {
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
        let text = sqlText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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
}
