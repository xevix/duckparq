import Foundation

/// What the status bar says about how much of a result is on screen.
///
/// The grid holds a window into a result rather than the result, and that
/// window does not always start at the top: End anchors it at the last page,
/// and scrolling up from there extends it backward. A bare count of loaded rows
/// cannot describe that. "500 of 3,000 rows" is read as *the first* 500, which
/// is exactly wrong when the 500 in question are the last ones — the reader is
/// looking at the end of the file and being told they are at the beginning.
///
/// So a window anchored anywhere but row 0 reports the rows it actually holds,
/// counting from the total: the last page of 3,000 rows is 2,501 through 3,000,
/// not 500. A window at the top is unchanged, where the loaded count already
/// says everything there is to say.
///
/// Here rather than inline in the status bar for the same reason `GridScroll`
/// is here: it is arithmetic, and arithmetic in a view cannot be checked.
public enum RowSummary {
    /// `loaded` rows are on screen starting at offset `windowStart`, out of
    /// `total` — nil while the count is still running, or for a statement that
    /// has no row count.
    public static func text(loaded: Int, windowStart: Int, total: Int?) -> String {
        guard let total else {
            return "\(loaded.formatted()) rows loaded"
        }
        // A window that has been moved off the top says where it sits. Guarded
        // on there being rows, since an empty window spans nothing and would
        // otherwise report a range that runs backward.
        if windowStart > 0, loaded > 0 {
            let first = windowStart + 1
            let last = windowStart + loaded
            return "\(first.formatted())–\(last.formatted()) of \(total.formatted()) rows"
        }
        if loaded >= total {
            return "\(total.formatted()) rows"
        }
        return "\(loaded.formatted()) of \(total.formatted()) rows"
    }
}
