import Foundation

/// Which folders the sidebar is showing the inside of, in the form that
/// survives a quit.
///
/// The set itself lives in `AppModel`; this is only the translation to and from
/// the list of paths that goes into defaults, and the pruning that has to
/// happen on the way back in. Paths rather than URLs because a path is what
/// defaults can hold, and because it settles the spelling: `/a/b/` and `/a/b`
/// are two unequal URLs for one folder, and both come out of `path` the same
/// way.
///
/// Reading is the side with rules, because a saved set describes a disk that
/// has since had a whole session of somebody else's changes made to it. An
/// entry is kept only when it still names a directory that still lies under an
/// added folder — anything else is a row the sidebar could never draw, and
/// keeping it would leave Collapse All lit with nothing to collapse.
public enum SidebarExpansion {
    /// The most folders worth remembering.
    ///
    /// Expand All opens thousands at once, and writing all of them back would
    /// grow defaults without bound for a state whose whole value is that it
    /// looks like where you left off. What survives the cap is the shallowest —
    /// the top of the tree, which is what is actually on screen; the folders
    /// deep inside it are the ones you would have had to scroll to anyway.
    public static let limit = 2_000

    /// The set as defaults should hold it.
    public static func encoded(_ folders: Set<URL>) -> [String] {
        capped(folders.map(\.path))
    }

    /// The saved paths, back as URLs the sidebar's rows can be found by.
    ///
    /// Each path is respelled onto the added folder that holds it — see
    /// `FileTree.chain(to:in:)`. The sidebar builds every row below a root by
    /// appending onto that root as the user chose it, and an expansion set that
    /// spells the same folder any other way is a set nothing in the tree
    /// matches.
    public static func decoded(_ paths: [String], under roots: [URL]) -> Set<URL> {
        var kept: [String] = []
        var respelled: [String: URL] = [:]
        for path in capped(paths) {
            let url = URL(fileURLWithPath: path)
            guard let match = FileTree.chain(to: url, in: roots)?.last, isDirectory(match)
            else { continue }
            // Two saved spellings of one folder collapse into one entry, so the
            // cap counts folders rather than strings.
            if respelled[match.path] == nil {
                respelled[match.path] = match
                kept.append(match.path)
            }
        }
        return Set(capped(kept).compactMap { respelled[$0] })
    }

    /// The paths worth keeping, shallowest first and alphabetical within a
    /// depth so the saved list is stable from one write to the next.
    private static func capped(_ paths: [String]) -> [String] {
        guard paths.count > limit else { return paths.sorted(by: shallowerFirst) }
        return Array(paths.sorted(by: shallowerFirst).prefix(limit))
    }

    private static func shallowerFirst(_ lhs: String, _ rhs: String) -> Bool {
        let left = depth(of: lhs)
        let right = depth(of: rhs)
        if left != right { return left < right }
        return lhs < rhs
    }

    private static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
