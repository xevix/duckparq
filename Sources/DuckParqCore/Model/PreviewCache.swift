import Foundation

/// What a source's bytes looked like when we last read it.
///
/// Not a hash of the data — hashing a 10 GB dataset to avoid reading it would
/// be self-defeating. It is what `stat` can answer cheaply: which files are
/// there, how big they are, and when they last changed. That misses a rewrite
/// that preserves size and timestamp, which in practice means a deliberately
/// backdated file; the Clear Cache button is the escape hatch for it, and the
/// cache is only ever consulted for the unfiltered first page anyway.
public struct SourceFingerprint: Sendable, Hashable {
    public let path: String
    public let fileCount: Int
    public let totalBytes: Int64
    /// Newest modification time across the source, in seconds since the epoch.
    public let newestModified: TimeInterval

    public init(path: String, fileCount: Int, totalBytes: Int64, newestModified: TimeInterval) {
        self.path = path
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.newestModified = newestModified
    }

    /// Stat a source. Returns nil when it cannot be characterised cheaply —
    /// a missing file, or a dataset with more files than `fileLimit`, where the
    /// walk would cost more than the query it is meant to save.
    ///
    /// Blocking. Call it off the main actor.
    public static func compute(for source: DataSource, fileLimit: Int = 20_000) -> SourceFingerprint? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]

        switch source {
        case .file(let url):
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return SourceFingerprint(
                path: url.path,
                fileCount: 1,
                totalBytes: Int64(values.fileSize ?? 0),
                newestModified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )

        case .dataset(let url):
            guard let walker = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return nil }

            var count = 0
            var bytes: Int64 = 0
            var newest: TimeInterval = 0
            for case let entry as URL in walker {
                guard FileTree.parquetExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                count += 1
                if count > fileLimit { return nil }
                guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
                bytes += Int64(values.fileSize ?? 0)
                newest = max(newest, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
            guard count > 0 else { return nil }
            return SourceFingerprint(path: url.path, fileCount: count, totalBytes: bytes, newestModified: newest)
        }
    }
}

/// The part of a result worth remembering: what the grid shows before you touch
/// anything.
public struct CachedPreview: Sendable {
    public let columns: [ColumnInfo]
    /// Row-major cells for the first page, exactly as they were fetched.
    public let rows: [[String?]]
    public let totalRowCount: Int?
    /// The first page was the whole result, so there is nothing more to stream.
    public let reachedEnd: Bool

    public init(columns: [ColumnInfo], rows: [[String?]], totalRowCount: Int?, reachedEnd: Bool) {
        self.columns = columns
        self.rows = rows
        self.totalRowCount = totalRowCount
        self.reachedEnd = reachedEnd
    }
}

/// Remembers the opening view of recently browsed sources.
///
/// Scope is deliberately narrow: **only the unfiltered, unsorted first page**,
/// and only for a file or dataset — never for SQL, never once a filter or sort
/// is applied. Those are the cases where a stale answer would be indistinguishable
/// from a real one; clicking back to a file you looked at a moment ago is not.
///
/// A cache hit still leaves the stream unopened, so scrolling past the first page
/// opens a cursor then — see `TableModel.loadMore()`.
public final class PreviewCache: @unchecked Sendable {
    public static let shared = PreviewCache()

    /// Small on purpose. Each entry holds a page of strings, and the value here
    /// is revisiting the handful of files you are actually working with.
    public let capacity: Int

    private let lock = NSLock()
    private var entries: [SourceFingerprint: CachedPreview] = [:]
    /// Least-recently-used first.
    private var order: [SourceFingerprint] = []

    public init(capacity: Int = 24) {
        self.capacity = capacity
    }

    public func preview(for fingerprint: SourceFingerprint) -> CachedPreview? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[fingerprint] else { return nil }
        touch(fingerprint)
        return entry
    }

    public func store(_ preview: CachedPreview, for fingerprint: SourceFingerprint) {
        lock.lock()
        defer { lock.unlock() }
        entries[fingerprint] = preview
        touch(fingerprint)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Caller holds the lock.
    private func touch(_ fingerprint: SourceFingerprint) {
        order.removeAll { $0 == fingerprint }
        order.append(fingerprint)
    }
}
