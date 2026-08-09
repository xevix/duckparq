import CoreServices
import Foundation

/// Watches the added folders so the sidebar keeps up with the disk.
///
/// A folder in the sidebar is meant to be a view of a directory, not a
/// photograph of it taken when it was first expanded. A file written by a job
/// running alongside the app, a partition landing in a dataset, a folder renamed
/// in Finder — all of it should show up without removing the folder and adding
/// it again.
///
/// FSEvents is what macOS offers for that: one stream over every added root,
/// reporting the directories whose contents changed. Directory granularity is
/// deliberate — without `kFSEventStreamCreateFlagFileEvents` the kernel says
/// "something under this folder changed" instead of naming a path per file,
/// which is both much cheaper and exactly the question the sidebar asks, which
/// is which folders have to be read again.
public final class DirectoryWatcher: @unchecked Sendable {

    /// A folder whose contents changed.
    public struct Change: Sendable, Hashable {
        public let url: URL
        /// Nothing below `url` can be assumed unchanged either — because events
        /// were dropped, or because the folder itself moved.
        public let includesSubdirectories: Bool

        public init(url: URL, includesSubdirectories: Bool = false) {
            self.url = url
            self.includesSubdirectories = includesSubdirectories
        }
    }

    /// What the C callback calls into.
    ///
    /// The stream holds this rather than the watcher, and holds it through the
    /// context's retain and release hooks, so an event already queued when the
    /// watcher goes away still has something valid to reach.
    private final class Sink: @unchecked Sendable {
        let report: @Sendable ([Change]) -> Void
        init(_ report: @escaping @Sendable ([Change]) -> Void) { self.report = report }
    }

    /// How long FSEvents may sit on events to coalesce them.
    ///
    /// A directory being written to produces an event per file otherwise, and
    /// each one costs a re-read of the folder. A third of a second is below
    /// noticing and well above the rate anything writes at.
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "dev.xevix.duckparq.directory-watcher")
    private let sink: Sink
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    /// The paths the current stream covers, sorted, so re-watching the same set
    /// can be recognised as the no-op it is.
    private var watched: [String] = []

    public init(latency: TimeInterval = 0.3, onChange: @escaping @Sendable ([Change]) -> Void) {
        self.latency = latency
        self.sink = Sink(onChange)
    }

    deinit { stop() }

    /// Watch exactly these folders and nothing else.
    ///
    /// A no-op when the set is already the one being watched. `AppModel.roots`
    /// is written for every change to the sidebar, including ones that leave the
    /// folders alone, and rebuilding the stream each time would drop every event
    /// that arrived in the gap.
    public func watch(_ roots: [URL]) {
        let paths = Set(roots.map(\.path)).sorted()
        lock.lock()
        defer { lock.unlock() }
        guard paths != watched else { return }

        tearDown()
        watched = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Sink>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Sink>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        // `SinceNow` because the folders are read as they are drawn: everything
        // before this moment is already on screen, and replaying it would only
        // re-read folders that are current.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                // NoDefer: report the first change of a burst straight away and
                // coalesce what follows, rather than making every change wait
                // out the latency.
                kFSEventStreamCreateFlagNoDefer
                // WatchRoot: an added folder that is itself moved or deleted is
                // worth hearing about — its rows are describing something that
                // is no longer there.
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        // Starting can fail — the per-user event stream limit — and there is
        // nothing useful to do about it beyond not holding a stream that is not
        // running. The sidebar then behaves exactly as it did before there was
        // a watcher at all.
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            watched = []
            return
        }
        stream = created
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        tearDown()
        watched = []
    }

    /// Whether a stream is running. Watching nothing is not an error, so this is
    /// how a caller tells "no folders" from "no stream".
    public var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    /// Caller holds the lock.
    private func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The C entry point. Captures nothing, which is what lets it convert to a
    /// plain function pointer; the sink comes back out of the context.
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, count > 0 else { return }
        guard let names = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }

        var changes: [Change] = []
        changes.reserveCapacity(min(count, names.count))
        for (index, name) in names.enumerated() where index < count {
            changes.append(Change(
                url: URL(fileURLWithPath: name, isDirectory: true),
                includesSubdirectories: (flags[index] & subtreeFlags) != 0
            ))
        }
        guard !changes.isEmpty else { return }
        Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().report(changes)
    }

    /// The flags that mean "and everything below it".
    ///
    /// A dropped event is not a missing event: the kernel is saying it stopped
    /// queueing them and the subtree has to be read again. A root that moved is
    /// the same situation for a different reason — every path below it is now
    /// describing a folder that has gone.
    private static let subtreeFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagRootChanged
    )
}
