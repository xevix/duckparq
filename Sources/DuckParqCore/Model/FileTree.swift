import Foundation

public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let byteSize: Int64?
    public let modified: Date?
    /// Which reader opens this row: from the extension for a file, and from
    /// the files underneath for a folder that reads as one dataset. Nil for an
    /// ordinary folder, which is a place to browse rather than a thing to read.
    public let format: FileFormat?

    public init(
        url: URL,
        isDirectory: Bool,
        byteSize: Int64?,
        modified: Date?,
        format: FileFormat?
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.modified = modified
        self.format = format
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// A directory that reads as one dataset — either hive-partitioned
    /// (`key=value` subdirectories) or holding data files that agree on a
    /// schema. See `FileTree.datasetFormat`.
    ///
    /// Derived rather than stored: a folder is a dataset exactly when some
    /// reader claims it, so the badge and the reader can never disagree.
    public var isDataset: Bool { isDirectory && format != nil }

    /// The same node with the dataset question answered.
    ///
    /// Deciding it costs a read of every file's schema, so it is not something a
    /// directory listing can do for every row it produces — see
    /// `FileTree.children(of:)`. The listing describes what is on disk and this
    /// stamps on what DuckDB said about it.
    public func classified(asDatasetOf format: FileFormat?) -> FileNode {
        FileNode(
            url: url, isDirectory: isDirectory,
            byteSize: byteSize, modified: modified, format: format
        )
    }

    public var dataSource: DataSource? {
        guard let format else { return nil }
        if isDirectory { return isDataset ? .dataset(url, format: format) : nil }
        return .file(url, format: format)
    }

    public var formattedSize: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// A node for a single data file, with its size and date read from disk.
    ///
    /// Files reached from outside a directory listing — opened from Finder, or
    /// remembered from a previous launch — still have to look like every other
    /// row, so they are described the same way.
    public static func file(at url: URL) -> FileNode {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileNode(
            url: url,
            isDirectory: false,
            byteSize: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            format: FileFormat.of(url) ?? .parquet
        )
    }
}

public enum FileTree {
    /// Why a directory listing came back empty.
    public enum ListingOutcome: Sendable, Equatable {
        case ok
        /// macOS denied access — Downloads, Desktop and Documents are
        /// TCC-protected, and re-picking the folder in an open panel grants it.
        case permissionDenied
        /// A hive layout, whose `key=value` sub-directories were withheld
        /// deliberately. They are partitions of one table, not folders worth
        /// browsing — see `isHivePartitioned`.
        case hivePartitioned
        case failed(String)
    }

    public struct Listing: Sendable {
        public let nodes: [FileNode]
        public let outcome: ListingOutcome
    }

    /// Directory contents with each sub-folder classified — what the sidebar
    /// draws.
    ///
    /// Async because classifying a folder means asking DuckDB whether its files
    /// read as one table; see `datasetFormat`. `children(of:)` is the same
    /// listing without that question, for the callers that walk the tree rather
    /// than draw it.
    public static func listing(of url: URL) async -> Listing {
        let listing = contents(of: url)
        var nodes = listing.nodes
        for index in nodes.indices where nodes[index].isDirectory {
            nodes[index] = nodes[index].classified(
                asDatasetOf: await datasetFormat(nodes[index].url)
            )
        }
        return Listing(nodes: nodes, outcome: listing.outcome)
    }

    /// Directory contents: sub-directories and data files, directories first,
    /// each side alphabetical. Everything else is hidden — this is a columnar
    /// file browser, not a file manager.
    ///
    /// Every directory node comes back with no format, because that question
    /// costs a read of every file's schema and this is what the tree walks are
    /// built on — Expand All, and the sidebar's filter. Both want names and
    /// which rows are folders; the filter classifies the handful it is actually
    /// about to show.
    public static func children(of url: URL) -> [FileNode] {
        contents(of: url).nodes
    }

    /// The listing as it comes off the filesystem, distinguishing "nothing here"
    /// from "not allowed to look" so the sidebar can offer the right remedy
    /// instead of silently showing an empty folder.
    private static func contents(of url: URL) -> Listing {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
        ]
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
            // A hive layout is one table. Listing `year=2024/month=01/…` invites
            // opening a partition as though it were a file of its own, which is
            // never what you want from a partitioned dataset — so the partitions
            // are withheld and the folder is offered whole.
            let hive = containsHivePartitions(entries)
            return Listing(
                nodes: nodes(from: entries, keys: keys, includingDirectories: !hive),
                outcome: hive ? .hivePartitioned : .ok
            )
        } catch let error as NSError {
            let denied = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoPermissionError || error.code == NSFileReadUnknownError)
            return Listing(nodes: [], outcome: denied ? .permissionDenied : .failed(error.localizedDescription))
        }
    }

    private static func nodes(
        from entries: [URL],
        keys: [URLResourceKey],
        includingDirectories: Bool = true
    ) -> [FileNode] {

        var nodes: [FileNode] = []
        nodes.reserveCapacity(entries.count)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                guard includingDirectories else { continue }
                nodes.append(FileNode(
                    url: entry,
                    isDirectory: true,
                    byteSize: nil,
                    modified: values?.contentModificationDate,
                    format: nil
                ))
            } else if let format = FileFormat.of(entry) {
                nodes.append(FileNode(
                    url: entry,
                    isDirectory: false,
                    byteSize: values?.fileSize.map(Int64.init),
                    modified: values?.contentModificationDate,
                    format: format
                ))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Whether a directory should offer to open as a single dataset rather than
    /// as a folder to browse, and if so which reader opens it.
    ///
    /// Two ways to qualify, in cost order:
    ///
    /// 1. **A hive layout.** `key=value` sub-directories are partition columns
    ///    of one table — which is how DuckDB's `hive_partitioning` reads them,
    ///    so it is how they are read here. Settled from the names alone.
    /// 2. **Files that agree on a schema**, so that one glob covers them without
    ///    `union_by_name = true`. Nothing in a folder's names says whether its
    ///    files agree, so this half is asked of DuckDB — see `DatasetIndex`.
    ///
    /// The second test is only reached for a folder holding data files of its
    /// own. A folder of folders stays a folder: it has no files to agree about,
    /// and badging one as a dataset would take a whole tree's worth of browsing
    /// away on the strength of what happens to be nested below it.
    ///
    /// A folder holding both parquet and vortex files reads as whichever it
    /// holds more of — see `shallowFormat`.
    public static func datasetFormat(_ url: URL) async -> FileFormat? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let hive = containsHivePartitions(entries)
        // A hive layout keeps its files in the partitions rather than at the
        // top, so the format is looked for below only when it is not up here.
        guard let format = shallowFormat(entries)
                ?? (hive ? format(belowChildrenOf: entries, depthLimit: datasetDescentDepth) : nil)
        else { return nil }
        if hive { return format }
        return await DatasetIndex.shared.readsAsOneTable(url, format: format) ? format : nil
    }

    /// Whether `url` reads as one table, without saying which reader does it.
    public static func looksLikeDataset(_ url: URL) async -> Bool {
        await datasetFormat(url) != nil
    }

    /// The format of the data files directly inside a directory — the cheap
    /// precondition that keeps an ordinary folder from ever reaching DuckDB.
    /// Nil when it holds none.
    ///
    /// A folder can hold more than one format, and in practice often does: a
    /// file and its conversion sitting side by side is how anyone tries a new
    /// format out. One glob names one extension, so one of them has to be
    /// picked, and the rule is the one a reader would guess — **the format most
    /// of the folder is in**, with parquet breaking a tie.
    ///
    /// That the other files are then left out of the dataset is a real cost,
    /// and it is why the tie goes to parquet: before vortex, a folder holding
    /// `data.parquet` and nothing else it recognised opened as one parquet
    /// table, and a `data.vortex` appearing beside it must not take that away.
    /// Either file can still be opened on its own, which is what the rows
    /// beneath the folder are for.
    private static func shallowFormat(_ entries: [URL]) -> FileFormat? {
        var counts: [FileFormat: Int] = [:]
        for format in dataFiles(in: entries).compactMap(FileFormat.of) {
            counts[format, default: 0] += 1
        }
        // Ties go to whichever case is declared first on `FileFormat`, which
        // puts the precedence where the formats themselves are written and
        // keeps this a strict ordering however many of them there are.
        return counts.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return precedence($0.key) > precedence($1.key)
        }?.key
    }

    private static func precedence(_ format: FileFormat) -> Int {
        FileFormat.allCases.firstIndex(of: format) ?? .max
    }

    /// The format of the files somewhere below a directory that holds none
    /// itself — how a hive layout, whose top level is all `key=value` folders,
    /// is asked what its partitions are made of.
    ///
    /// Descends into the first sub-directory that answers rather than walking
    /// the whole tree: a partitioned dataset is uniform by construction, and
    /// the tree in question can be a hundred thousand files. Bounded by depth
    /// for the same reason `unbranchedDescent` is — a symlink pointing back up
    /// its own chain would otherwise never end.
    private static let datasetDescentDepth = 8

    private static func format(under url: URL, depthLimit: Int) -> FileFormat? {
        guard depthLimit > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              )
        else { return nil }

        return shallowFormat(entries)
            ?? format(belowChildrenOf: entries, depthLimit: depthLimit)
    }

    /// The descent half, taking entries the caller has already read.
    ///
    /// Split out because the caller that matters — `datasetFormat` — has the
    /// directory's contents in hand and has already found no format among them.
    /// Handing them over rather than the URL saves a second listing of the
    /// folder and a second scan of it, on every classification of every hive
    /// tree, on every keystroke of the sidebar's filter.
    private static func format(belowChildrenOf entries: [URL], depthLimit: Int) -> FileFormat? {
        for entry in entries.prefix(256) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if let below = format(under: entry, depthLimit: depthLimit - 1) { return below }
        }
        return nil
    }

    /// A `key=value` directory name — the shape DuckDB's `hive_partitioning`
    /// reads as a partition column, so it is the shape we treat as one too.
    ///
    /// The `=` may not be first: `=2024` names no key, and a file called
    /// `report=final.parquet` is a file, which is why the caller also checks it
    /// is a directory.
    public static func isHivePartitionName(_ name: String) -> Bool {
        guard let separator = name.firstIndex(of: "=") else { return false }
        return separator != name.startIndex
    }

    /// Whether a directory's children are hive partitions rather than folders
    /// worth browsing.
    public static func isHivePartitioned(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return false }
        return containsHivePartitions(entries)
    }

    /// The key naming a hive layout's outermost partition — the `year` in
    /// `year=2024/region=us/` — or nil for anything not partitioned that way.
    ///
    /// This is the column the dataset is physically laid out by, which is what
    /// makes it the one worth ordering by: its value comes from the path
    /// rather than the data, so DuckDB can order by it without reading a
    /// column, and can skip whole partitions it does not need.
    ///
    /// Bounded like `containsHivePartitions`, and for the same reason: a
    /// dataset of many thousands of partitions should not be walked to answer
    /// a question the first partition answers.
    public static func topLevelHiveKey(of url: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        for entry in entries.prefix(256) {
            let name = entry.lastPathComponent
            guard isHivePartitionName(name),
                  let separator = name.firstIndex(of: "="),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            return String(name[name.startIndex..<separator])
        }
        return nil
    }

    private static func containsHivePartitions(_ entries: [URL]) -> Bool {
        for entry in entries.prefix(256) {
            guard isHivePartitionName(entry.lastPathComponent) else { continue }
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return true
            }
        }
        return false
    }

    /// The readable data files among some URLs, in the order given.
    ///
    /// Used to sift a drop, which can carry anything the Finder had selected.
    /// A directory is excluded even when its name ends in `.parquet`: a folder
    /// is a dataset, which is a different thing to open.
    public static func dataFiles(in urls: [URL]) -> [URL] {
        urls.filter { url in
            guard FileFormat.isReadable(url) else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
    }

    /// The folders among some URLs, in the order given.
    ///
    /// The other half of sifting a drop. A folder dragged in is a folder to
    /// browse — the same thing Add Folder… produces — so it is picked out
    /// rather than ignored, and a drop holding both kinds does both.
    public static func directories(in urls: [URL]) -> [URL] {
        urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    // MARK: - Opening a folder that holds one folder

    /// The folders to open along with `url` when it is expanded: the run below
    /// it that holds nothing but one more folder.
    ///
    /// A tree like `common-crawl/cc-index/table/cc-main/warc` costs four clicks
    /// to reach anything, and the first three of them land on a folder whose
    /// single row exists only to be clicked in turn. Expanding a folder opens
    /// that whole run instead, so the click arrives at the first place the tree
    /// actually branches.
    ///
    /// Where it stops is what keeps that from overreaching:
    ///
    ///   - **Two or more rows.** There is something to choose between, and the
    ///     choice is the reader's to make.
    ///   - **A dataset.** The `warc` above: opening it is a table to read, not a
    ///     level to pass through — see `looksLikeDataset`. It is left shut, one
    ///     row below its now-open parent, which is where it can be seen and
    ///     clicked.
    ///   - **A file.** Nothing below it to open.
    ///
    /// Rows are counted as the sidebar draws them, since it is the sidebar's
    /// single row this is about: `children(of:)` lists folders and data
    /// files, so a folder holding one folder and a stray `README` is still one
    /// row, and still passed through.
    ///
    /// `url` itself is never included — the caller has already expanded it. The
    /// walk is bounded because it reads one directory at a time and a symlink
    /// pointing back up its own chain would otherwise never end.
    public static func unbranchedDescent(from url: URL, limit: Int = 32) async -> [URL] {
        var chain: [URL] = []
        var current = url
        while chain.count < limit {
            let rows = children(of: current)
            guard rows.count == 1, let only = rows.first, only.isDirectory else { break }
            // Asked only of the folder about to be walked into. This is the
            // question `children(of:)` refuses to answer for every row it
            // produces, and a chain of only-children is few enough rows to ask
            // it about one at a time.
            if await looksLikeDataset(only.url) { break }
            chain.append(only.url)
            current = only.url
        }
        return chain
    }

    // MARK: - Locating a file in the added roots

    /// The components of `url` below `directory`, or nil when `url` is not
    /// below it.
    ///
    /// Compared component-wise rather than as strings: `/data/sales` is not a
    /// prefix-match for `/data/sales-2024`, but the string test says it is. It
    /// is also trailing-slash-proof, which plain `URL` equality is not — a
    /// directory listing hands back `file:///a/b/` where an open panel hands
    /// back `file:///a/b`, and those two URLs are not equal.
    ///
    /// Symlinks are resolved only as a fallback. Finder passes `/private/var/…`
    /// for a root that was added as `/var/…`, and the two resolve alike; doing
    /// it unconditionally would instead rewrite paths that already matched.
    public static func relativeComponents(of url: URL, under directory: URL) -> [String]? {
        func descent(from base: [String], to candidate: [String]) -> [String]? {
            guard candidate.count > base.count, Array(candidate.prefix(base.count)) == base
            else { return nil }
            return Array(candidate.dropFirst(base.count))
        }

        if let found = descent(from: directory.pathComponents, to: url.pathComponents) {
            return found
        }
        return descent(from: resolvedComponents(directory), to: resolvedComponents(url))
    }

    /// A URL's components with the symlinks in its path resolved.
    ///
    /// `resolvingSymlinksInPath` resolves nothing at all when the path does not
    /// exist, and the leaf here is a file that may since have been moved. The
    /// directory is what carries the symlink worth resolving, so it is resolved
    /// on its own and the name put back.
    private static func resolvedComponents(_ url: URL) -> [String] {
        let resolved = url.resolvingSymlinksInPath()
        if resolved.path != url.path { return resolved.pathComponents }
        return url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
            .pathComponents
    }

    /// Whether `url` lies somewhere below `directory`.
    public static func contains(_ directory: URL, _ url: URL) -> Bool {
        relativeComponents(of: url, under: directory) != nil
    }

    /// The added root `url` sits under.
    ///
    /// The deepest match wins: with both `/data` and `/data/sales` added, a file
    /// in the latter is revealed there rather than several levels down the
    /// former, which is the shorter trip for the reader.
    public static func root(containing url: URL, in roots: [URL]) -> URL? {
        roots
            .filter { contains($0, url) }
            .max { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// Every directory that has to be open for `url` to be on screen: `root`
    /// itself, then each directory down to the one holding `url`.
    ///
    /// The URLs are built by appending onto `root` as the caller spelled it, so
    /// they compare equal to the ones a directory listing produces — which is
    /// what the sidebar's expansion set is holding.
    public static func ancestors(of url: URL, upTo root: URL) -> [URL] {
        chain(to: url, under: root)?.dropLast().map { $0 } ?? []
    }

    /// `root`, each directory below it, and `url` itself last — or nil when
    /// `url` is not `root` and does not lie under it.
    ///
    /// Same construction as `ancestors`, and the reason both exist is the same:
    /// the URLs are respelled onto `root`. What makes the inclusive form worth
    /// having separately is where the paths come from. FSEvents answers in
    /// resolved, canonical paths — `/private/var/…` for a folder added as
    /// `/var/…`, never with a trailing slash — while every row in the sidebar
    /// was built by appending onto the root as the user chose it. Those are two
    /// unequal URLs for one folder, so a change reported by the system has to be
    /// put back into the sidebar's spelling before anything keyed on its rows
    /// can be found by it.
    public static func chain(to url: URL, under root: URL) -> [URL]? {
        if isSameDirectory(root, url) { return [root] }
        guard let relative = relativeComponents(of: url, under: root) else { return nil }
        var chain = [root]
        var current = root
        for component in relative {
            current = current.appendingPathComponent(component)
            chain.append(current)
        }
        return chain
    }

    /// The chain under whichever added root holds `url`, deepest root first —
    /// the same rule `root(containing:in:)` uses, and for the same reason.
    public static func chain(to url: URL, in roots: [URL]) -> [URL]? {
        roots
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
            .lazy
            .compactMap { chain(to: url, under: $0) }
            .first
    }

    /// Whether two URLs name the same directory.
    ///
    /// Component-wise rather than by `URL` equality, which a trailing slash
    /// breaks, and with symlinks resolved only as a fallback — see
    /// `relativeComponents`, which is careful about both for the same reasons.
    public static func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.pathComponents == rhs.pathComponents { return true }
        return resolvedComponents(lhs) == resolvedComponents(rhs)
    }

    /// Recursive name search, used by the sidebar's filter field. Bounded so a
    /// search over a huge tree can't hang the UI.
    ///
    /// The walk itself is unclassified — twenty thousand folders is far too many
    /// to ask DuckDB about, and the answer would be thrown away for all but the
    /// few whose names match. Only a folder that matched, and so is about to be
    /// shown, is classified; a folder that turns out not to be a dataset is not
    /// a result at all, because there is nothing to open it as.
    public static func search(root: URL, query: String, limit: Int = 300) async -> [FileNode] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [FileNode] = []
        var queue: [URL] = [root]
        var visited = 0

        while !queue.isEmpty, results.count < limit, visited < 20_000 {
            let directory = queue.removeFirst()
            for node in children(of: directory) {
                visited += 1
                if node.isDirectory {
                    queue.append(node.url)
                    if node.name.lowercased().contains(needle),
                       let format = await datasetFormat(node.url) {
                        results.append(node.classified(asDatasetOf: format))
                    }
                } else if node.name.lowercased().contains(needle) {
                    results.append(node)
                }
                if results.count >= limit { break }
            }
        }
        return results
    }
}
