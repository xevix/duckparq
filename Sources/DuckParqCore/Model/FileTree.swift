import Foundation

public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// A directory that reads as one parquet dataset — either hive-partitioned
    /// (`key=value` subdirectories) or holding parquet files that agree on a
    /// schema. See `FileTree.looksLikeDataset`.
    public let isDataset: Bool
    public let byteSize: Int64?
    public let modified: Date?

    public init(url: URL, isDirectory: Bool, isDataset: Bool, byteSize: Int64?, modified: Date?) {
        self.url = url
        self.isDirectory = isDirectory
        self.isDataset = isDataset
        self.byteSize = byteSize
        self.modified = modified
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// The same node with the dataset question answered.
    ///
    /// Deciding it costs a read of every file's schema, so it is not something a
    /// directory listing can do for every row it produces — see
    /// `FileTree.children(of:)`. The listing describes what is on disk and this
    /// stamps on what DuckDB said about it.
    public func classified(asDataset isDataset: Bool) -> FileNode {
        FileNode(
            url: url, isDirectory: isDirectory, isDataset: isDataset,
            byteSize: byteSize, modified: modified
        )
    }

    public var dataSource: DataSource? {
        if isDirectory { return isDataset ? .dataset(url) : nil }
        return .file(url)
    }

    public var formattedSize: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// A node for a single parquet file, with its size and date read from disk.
    ///
    /// Files reached from outside a directory listing — opened from Finder, or
    /// remembered from a previous launch — still have to look like every other
    /// row, so they are described the same way.
    public static func file(at url: URL) -> FileNode {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileNode(
            url: url,
            isDirectory: false,
            isDataset: false,
            byteSize: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate
        )
    }
}

public enum FileTree {
    public static let parquetExtensions: Set<String> = ["parquet", "pq", "parq"]

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
    /// read as one table; see `looksLikeDataset`. `children(of:)` is the same
    /// listing without that question, for the callers that walk the tree rather
    /// than draw it.
    public static func listing(of url: URL) async -> Listing {
        let listing = contents(of: url)
        var nodes = listing.nodes
        for index in nodes.indices where nodes[index].isDirectory {
            nodes[index] = nodes[index].classified(
                asDataset: await looksLikeDataset(nodes[index].url)
            )
        }
        return Listing(nodes: nodes, outcome: listing.outcome)
    }

    /// Directory contents: sub-directories and parquet files, directories first,
    /// each side alphabetical. Everything else is hidden — this is a parquet
    /// browser, not a file manager.
    ///
    /// Every directory node comes back `isDataset: false`, because that question
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
                    isDataset: false,
                    byteSize: nil,
                    modified: values?.contentModificationDate
                ))
            } else if parquetExtensions.contains(entry.pathExtension.lowercased()) {
                nodes.append(FileNode(
                    url: entry,
                    isDirectory: false,
                    isDataset: false,
                    byteSize: values?.fileSize.map(Int64.init),
                    modified: values?.contentModificationDate
                ))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Whether a directory should offer to open as a single dataset rather than
    /// as a folder to browse.
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
    /// The second test is only reached for a folder holding parquet files of its
    /// own. A folder of folders stays a folder: it has no files to agree about,
    /// and badging one as a dataset would take a whole tree's worth of browsing
    /// away on the strength of what happens to be nested below it.
    public static func looksLikeDataset(_ url: URL) async -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return false }

        if containsHivePartitions(entries) { return true }
        guard containsParquetFile(entries) else { return false }
        return await DatasetIndex.shared.readsAsOneTable(url)
    }

    /// Whether any of these entries is a parquet file — the cheap precondition
    /// that keeps an ordinary folder from ever reaching DuckDB. Short-circuits,
    /// so a folder whose first entry is a parquet file costs one `stat`.
    private static func containsParquetFile(_ entries: [URL]) -> Bool {
        entries.contains { entry in
            parquetExtensions.contains(entry.pathExtension.lowercased())
                && (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
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

    /// The parquet files among some URLs, in the order given.
    ///
    /// Used to sift a drop, which can carry anything the Finder had selected.
    /// A directory is excluded even when its name ends in `.parquet`: a folder
    /// is a dataset, which is a different thing to open.
    public static func parquetFiles(in urls: [URL]) -> [URL] {
        urls.filter { url in
            guard parquetExtensions.contains(url.pathExtension.lowercased()) else { return false }
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
        guard let relative = relativeComponents(of: url, under: root) else { return [] }
        var chain = [root]
        var current = root
        for component in relative.dropLast() {
            current = current.appendingPathComponent(component)
            chain.append(current)
        }
        return chain
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
                    if node.name.lowercased().contains(needle), await looksLikeDataset(node.url) {
                        results.append(node.classified(asDataset: true))
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
