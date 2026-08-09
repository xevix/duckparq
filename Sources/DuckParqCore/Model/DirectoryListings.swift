import Foundation
import Observation

/// One folder's rows, as the sidebar is drawing them.
///
/// The rows live here rather than in the view that shows them because they now
/// have a second author. A view can pull a directory in when it appears; a
/// watcher has to push one in at a moment nothing is appearing, into a folder
/// that may not even be on screen — and `@State` inside a row is reachable only
/// from that row, only while it exists.
@MainActor
@Observable
public final class DirectoryListing {
    public let url: URL
    public private(set) var nodes: [FileNode] = []
    public private(set) var outcome: FileTree.ListingOutcome = .ok
    /// Whether the folder has ever been read. Distinguishes an empty folder,
    /// which has an answer, from one that has not been looked at yet.
    public private(set) var isLoaded = false
    /// Whether the folder itself reads as one dataset — see
    /// `FileTree.looksLikeDataset`.
    public private(set) var isDataset = false
    /// Bumped whenever a read finishes, so a test can watch for one.
    public private(set) var reads = 0

    @ObservationIgnored private var reader: Task<(FileTree.Listing, Bool), Never>?
    /// Which read is the current one. A `Task` is a value, so there is nothing
    /// to compare two of them by; this is what a finished read checks itself
    /// against before publishing.
    @ObservationIgnored private var readerGeneration = 0

    public init(url: URL) {
        self.url = url
    }

    /// Read the folder, unless it has been read already or is being read now.
    public func load() async {
        if let reader {
            _ = await reader.value
            return
        }
        guard !isLoaded else { return }
        await refresh()
    }

    /// Read the folder again.
    ///
    /// Whatever is on screen stays there until the new rows arrive: a folder
    /// being written into would otherwise blink back to "Loading…" every time a
    /// file landed in it, which is a worse way to say "one file was added" than
    /// saying nothing at all.
    ///
    /// A read already running is superseded rather than waited for — it is
    /// looking at a directory that has since changed, which is what prompted
    /// this call.
    public func refresh() async {
        reader?.cancel()
        readerGeneration += 1
        let generation = readerGeneration
        // Both halves are nonisolated, so both run off the main actor: the
        // directory read, which is slow on a network volume, and the schema
        // probe behind the badge, which is a query. The sidebar stays
        // responsive while they do.
        let task = Task { [url] in
            (await FileTree.listing(of: url), await FileTree.looksLikeDataset(url))
        }
        reader = task

        let (listing, dataset) = await task.value
        // Cancellation cannot stop a directory read in progress, so a superseded
        // read still finishes and still has an answer. Dropping it here is what
        // keeps the older answer from landing on top of the newer one.
        guard generation == readerGeneration else { return }
        reader = nil
        nodes = listing.nodes
        outcome = listing.outcome
        isDataset = dataset
        isLoaded = true
        reads += 1
    }
}

/// Every folder the sidebar has read, and the way a change on disk reaches them.
///
/// Deliberately not `@Observable` itself. Views reach a folder through this and
/// then observe that folder alone, so a file landing in one directory redraws
/// one directory — an observable dictionary would redraw every open folder in
/// the tree instead.
///
/// Entries outlive collapsing the folder that made them. Re-expanding is then
/// instant, and the staleness that would normally argue against keeping them is
/// what the watcher is for.
@MainActor
public final class DirectoryListings {
    /// Keyed by path: `URL` equality turns on a trailing slash, and a folder
    /// reached through a listing is not spelled the way the same folder reached
    /// through an open panel is.
    private var listings: [String: DirectoryListing] = [:]

    public init() {}

    /// The folder's rows, reading them for the first time if nothing has yet.
    public func listing(for url: URL) -> DirectoryListing {
        if let existing = listings[url.path] { return existing }
        let created = DirectoryListing(url: url)
        listings[url.path] = created
        return created
    }

    /// Whether a folder's rows have been read, without asking for them to be.
    public func isLoaded(_ url: URL) -> Bool {
        listings[url.path]?.isLoaded ?? false
    }

    public var count: Int { listings.count }

    /// Drop everything remembered about a folder and what is under it — what
    /// removing an added folder from the sidebar leaves behind.
    public func forget(under root: URL) {
        let prefix = root.path + "/"
        listings = listings.filter { path, _ in
            path != root.path && !path.hasPrefix(prefix)
        }
    }

    /// Take what the watcher saw and put the sidebar back in step with it.
    ///
    /// Three folders can be wrong after one change, and all three are refreshed:
    ///
    /// 1. **The folder named.** Its files and sub-folders are what changed.
    /// 2. **Every folder above it, up to the added root.** A folder's dataset
    ///    badge is decided by globbing it *recursively*, so a file appearing
    ///    several levels down can be the file that stops an ancestor reading as
    ///    one table — see `FileTree.looksLikeDataset`.
    /// 3. **Everything below it**, when the change came with a dropped-events
    ///    flag and so covers a subtree rather than a directory.
    ///
    /// A folder no one has looked at is not read here — there are no rows to
    /// correct — but its classification is still forgotten, because that answer
    /// is kept for the life of the process and would otherwise be waiting,
    /// already stale, for the first time the folder is expanded.
    public func directoriesDidChange(_ changes: [DirectoryWatcher.Change], in roots: [URL]) {
        var stale: [String: URL] = [:]
        for change in changes {
            guard let chain = FileTree.chain(to: change.url, in: roots) else { continue }
            for url in chain { stale[url.path] = url }
            guard change.includesSubdirectories, let deepest = chain.last else { continue }
            let prefix = deepest.path + "/"
            for (path, listing) in listings where path.hasPrefix(prefix) {
                stale[path] = listing.url
            }
        }
        guard !stale.isEmpty else { return }

        let forgotten = Array(stale.values)
        let held = forgotten.compactMap { listings[$0.path] }
        Task {
            // Classification first, and all of it, before any folder is read
            // back: a listing classifies the folders in it, and re-reading one
            // against answers that are still stale would only cache them again.
            for url in forgotten { await DatasetIndex.shared.invalidate(url) }
            for listing in held { await listing.refresh() }
        }
    }
}
