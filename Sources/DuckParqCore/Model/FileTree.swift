import Foundation

public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// A directory that reads as one parquet dataset — either hive-partitioned
    /// (`key=value` subdirectories) or simply holding parquet files.
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

    public var dataSource: DataSource? {
        if isDirectory { return isDataset ? .dataset(url) : nil }
        return .file(url)
    }

    public var formattedSize: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
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
        case failed(String)
    }

    public struct Listing: Sendable {
        public let nodes: [FileNode]
        public let outcome: ListingOutcome
    }

    /// Directory contents, distinguishing "nothing here" from "not allowed to
    /// look" so the sidebar can offer the right remedy instead of silently
    /// showing an empty folder.
    public static func listing(of url: URL) -> Listing {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
        ]
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
            return Listing(nodes: nodes(from: entries, keys: keys), outcome: .ok)
        } catch let error as NSError {
            let denied = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoPermissionError || error.code == NSFileReadUnknownError)
            return Listing(nodes: [], outcome: denied ? .permissionDenied : .failed(error.localizedDescription))
        }
    }

    /// Directory contents: sub-directories and parquet files, directories first,
    /// each side alphabetical. Everything else is hidden — this is a parquet
    /// browser, not a file manager.
    public static func children(of url: URL) -> [FileNode] {
        listing(of: url).nodes
    }

    private static func nodes(from entries: [URL], keys: [URLResourceKey]) -> [FileNode] {

        var nodes: [FileNode] = []
        nodes.reserveCapacity(entries.count)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                nodes.append(FileNode(
                    url: entry,
                    isDirectory: true,
                    isDataset: looksLikeDataset(entry),
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

    /// Whether a directory should offer to open as a single dataset.
    ///
    /// Deliberately a shallow, first-level check: this runs for every directory
    /// the sidebar draws, so it must not walk the tree. A hive layout is
    /// recognised by `key=value` directory names, which is how DuckDB's
    /// `hive_partitioning` reads them too.
    public static func looksLikeDataset(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return false }

        for entry in entries.prefix(64) {
            if parquetExtensions.contains(entry.pathExtension.lowercased()) { return true }
            let name = entry.lastPathComponent
            if name.contains("="),
               (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return true
            }
        }
        return false
    }

    /// Recursive name search, used by the sidebar's filter field. Bounded so a
    /// search over a huge tree can't hang the UI.
    public static func search(root: URL, query: String, limit: Int = 300) -> [FileNode] {
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
                    if node.isDataset, node.name.lowercased().contains(needle) {
                        results.append(node)
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
