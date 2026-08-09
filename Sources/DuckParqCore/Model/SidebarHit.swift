#if canImport(AppKit)
import AppKit

/// Whether a click in the sidebar landed on one of its rows or on the empty
/// space past the end of them.
///
/// Three ways of asking this look right and are not, which is why it is a type
/// with a comment rather than a line in a view:
///
/// An `.onTapGesture` on the container holding the `List` is the obvious
/// spelling, and it is completely silent. A list is an `NSTableView` behind a
/// hosting view and it answers a click on its own background itself, so nothing
/// is left over for a SwiftUI gesture behind it.
///
/// Asking AppKit what was clicked fails in a way that looks like it should work.
/// A click over a row hit-tests to the outline view itself rather than to
/// anything row-shaped, and a click past the last row hit-tests to *nothing at
/// all* — no view in the window claims it, which is the same reason the click
/// appears to vanish.
///
/// Comparing the click against the rows' rectangle fails for the reason the
/// first two do: SwiftUI sizes the document view to fill the viewport whether or
/// not it has the rows to fill it. Eleven rows 32 points tall end at y=339 in a
/// view whose frame runs to 1304, so "inside the rows' view" is true of the
/// whole empty area.
///
/// What is left is the table's own account of its rows, which is the one thing
/// here that knows where they stop.
public enum SidebarHit {
    /// True when `point` — in `rows`' own coordinates — is inside the list but
    /// on none of its rows.
    ///
    /// The bounds check is what keeps this to the sidebar. `row(at:)` answers
    /// -1 for anything off the rows, including the strip above them that the
    /// list scrolls under the toolbar, and a click on a toolbar button is not a
    /// click on an empty area of anything.
    @MainActor
    public static func isEmptyArea(_ point: CGPoint, in rows: NSTableView) -> Bool {
        guard rows.bounds.contains(point) else { return false }
        return rows.row(at: point) < 0
    }
}
#endif
