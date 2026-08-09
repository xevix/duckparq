import Foundation

/// Where the grid's viewport goes when something other than the user's hand
/// moves it.
///
/// Both moves have to be expressed as a **point**, and that is the whole reason
/// this exists. SwiftUI's `scrollTo(edge:)` and `scrollTo(y:)` each return the
/// horizontal offset to zero as a side effect, so a grid written with them
/// moved the columns every time it moved the rows: Home and End on a file wider
/// than the window walked the view back to the first column. Naming both axes
/// is what keeps the columns where the user left them, and the arithmetic that
/// decides the vertical half lives here — where it can be checked — rather than
/// inline in a view that cannot be.
public enum GridScroll {
    /// Which end of the result a Home or End landing is aimed at.
    ///
    /// SwiftUI's `Edge` says the same thing and two more besides — `leading`
    /// and `trailing`, which the grid never asks for and would not honour, a
    /// landing being a move of the rows that leaves the columns alone.
    public enum Edge: Sendable, Equatable {
        case top
        case bottom
    }

    /// Where the viewport goes for a Home or End landing: both coordinates,
    /// deliberately, since naming only one is what moved the columns.
    ///
    /// Its own type rather than `CGPoint` because Swift 6.3.3 cannot optimize a
    /// `CGPoint` returned across a module boundary — `swift-frontend` crashes
    /// in IRGen projecting its fields, which took out the release build and not
    /// the debug one. Two `CGFloat`s say the same thing and compile, and the
    /// grid turns them into the point it scrolls to.
    public struct Landing: Sendable, Equatable {
        public let x: CGFloat
        public let y: CGFloat

        public init(x: CGFloat, y: CGFloat) {
            self.x = x
            self.y = y
        }
    }

    /// The landing a Home or End press asks for, with the columns held at `x`.
    ///
    /// The bottom is a y past the end of any content rather than a measured
    /// one. The scroll view clamps it to the real end, and clamps it against
    /// the content as laid out — which is what a landing needs when the rows
    /// have only just been replaced by a window of a different height, and
    /// saves measuring a content height that would still be the old one at the
    /// moment the landing is asked for.
    public static func landing(on edge: Edge, keepingX x: CGFloat) -> Landing {
        switch edge {
        case .top:
            return Landing(x: x, y: 0)
        case .bottom:
            return Landing(x: x, y: .greatestFiniteMagnitude)
        }
    }

    /// Which way a Page Up or Page Down press moves the rows.
    ///
    /// Distinct from `Edge`, which is where a press *lands*. A page is a step
    /// of a known size from wherever the viewport already is, and the two
    /// cannot be spelled the same way: Home and End are absolute and need no
    /// current position, these are relative and are nothing without one.
    public enum PageDirection: Sendable, Equatable {
        case up
        case down
    }

    /// How far one Page Up or Page Down press moves the viewport.
    ///
    /// A screenful less one row, so the row at the boundary is shown twice
    /// rather than stepped over — the line you were reading when you pressed
    /// the key is still on screen afterward, which is what makes paging through
    /// a file readable rather than a series of disjoint screenfuls.
    ///
    /// Never less than a row, so the grid still moves when it is asked to: a
    /// viewport barely taller than a row would otherwise ask for a step of
    /// nothing, and a viewport of zero — which is what the grid reports before
    /// the scroll view has been laid out — for a step backward.
    public static func pageStep(viewportHeight: CGFloat, rowHeight: CGFloat) -> CGFloat {
        max(viewportHeight - rowHeight, rowHeight)
    }

    /// Where the viewport goes for a Page Up or Page Down press, with the
    /// columns held at `x` for the same reason a Home or End landing holds
    /// them: this moves the rows, and nothing about it asks for the columns to
    /// move too.
    ///
    /// Clamped at the top, and deliberately not at the bottom. Zero is a bound
    /// this can be sure of; the end of the content is not, since the rows the
    /// content is made of are still being paged in and a height measured here
    /// would be the height of whatever was loaded a moment ago. The scroll view
    /// clamps the far end against the rows as actually laid out, which is the
    /// one account of it that cannot be stale — the same bargain
    /// `landing(on: .bottom)` makes.
    public static func page(
        _ direction: PageDirection,
        from distanceFromTop: CGFloat,
        viewportHeight: CGFloat,
        rowHeight: CGFloat,
        keepingX x: CGFloat
    ) -> Landing {
        let step = pageStep(viewportHeight: viewportHeight, rowHeight: rowHeight)
        switch direction {
        case .up:
            return Landing(x: x, y: max(distanceFromTop - step, 0))
        case .down:
            return Landing(x: x, y: distanceFromTop + step)
        }
    }

    /// Which way an arrow key moves the viewport.
    ///
    /// Four cases where a page has two, because an arrow is the only key the
    /// grid answers that moves it *sideways*. Home, End, Page Up and Page Down
    /// all say something about the rows and nothing about the columns; the left
    /// and right arrows say the opposite, and are how a file far wider than the
    /// window is walked across without a trackpad.
    public enum ArrowDirection: Sendable, Equatable {
        case up
        case down
        case left
        case right
    }

    /// How far one left or right arrow press moves the columns.
    ///
    /// A distance rather than a column, because the columns here are of wildly
    /// different widths: a step of one column would cross half a screen on a
    /// wide text column and barely register on a narrow integer one, so the same
    /// key would move by an amount the user cannot predict. Roughly six
    /// characters of the 11pt monospaced cell font — small enough to aim with,
    /// large enough that holding the key gets somewhere.
    public static let arrowColumnStep: CGFloat = 40

    /// Where the viewport goes for one arrow-key press.
    ///
    /// This is the grid *without* a selected row, where the arrows are a way to
    /// move the view rather than a way to move through the rows. Vertically the
    /// step is one row — the smallest move that leaves the grid on a row
    /// boundary, so a column of values does not end up sliced in half across the
    /// top edge.
    ///
    /// Clamped at zero on both axes and unclamped at the far ends, which is the
    /// same bargain `page` makes: the near edge is a bound this can be sure of,
    /// while the far one belongs to the scroll view, which measures it against
    /// the rows and columns as actually laid out rather than as they were when
    /// the key was pressed.
    public static func arrow(
        _ direction: ArrowDirection,
        fromY y: CGFloat,
        x: CGFloat,
        rowHeight: CGFloat
    ) -> Landing {
        switch direction {
        case .up:
            return Landing(x: x, y: max(y - rowHeight, 0))
        case .down:
            return Landing(x: x, y: y + rowHeight)
        case .left:
            return Landing(x: max(x - arrowColumnStep, 0), y: y)
        case .right:
            return Landing(x: x + arrowColumnStep, y: y)
        }
    }

    /// Where the viewport must go for the row at `index` to be wholly on screen,
    /// or nil if it already is.
    ///
    /// Nil rather than the current offset, and the difference matters: arrowing
    /// through rows in the middle of a screenful should leave the view perfectly
    /// still, and a scroll "to where it already is" is not still — it cancels a
    /// momentum scroll and fights any animation in flight. So the answer to
    /// "does this need scrolling" is a value, not a comparison the caller has to
    /// make afterward.
    ///
    /// `index` is a row id — an offset into the whole result — so it is measured
    /// from `windowStart` rather than assumed to be a position in the loaded
    /// rows.
    ///
    /// The row is brought just inside the edge it fell outside, rather than
    /// centred: a selection moving down one row at a time should scroll one row
    /// at a time, not jump half a screen every time it reaches the bottom.
    public static func reveal(
        rowAt index: Int,
        windowStart: Int,
        rowHeight: CGFloat,
        distanceFromTop: CGFloat,
        viewportHeight: CGFloat,
        keepingX x: CGFloat
    ) -> Landing? {
        let top = max(CGFloat(index - windowStart) * rowHeight, 0)
        if top < distanceFromTop { return Landing(x: x, y: top) }
        // A viewport that cannot hold a whole row — including the zero-height
        // one the grid reports before the scroll view has been laid out — has no
        // "just inside the bottom edge" to land on, so the row's own top is the
        // only sensible place to put it.
        guard viewportHeight >= rowHeight else { return Landing(x: x, y: top) }
        let bottom = top + rowHeight
        guard bottom > distanceFromTop + viewportHeight else { return nil }
        return Landing(x: x, y: bottom - viewportHeight)
    }

    /// Where the viewport must move to hold its rows still when `prepended`
    /// rows are spliced in above it.
    ///
    /// A scroll view keeps its offset when content is inserted above the
    /// viewport, so a page of earlier rows arriving moves every row on screen
    /// down by the height of it. Two things follow, and the second is the one
    /// that reads as a bug: the rows being read jump away, and an offset that
    /// had reached zero — which is where scrolling up to ask for the page
    /// leaves it — has no further "up" to report, so the page after it cannot
    /// be asked for until the user scrolls back down. Moving the viewport down
    /// by exactly the height of what arrived undoes both.
    public static func offsetAfterPrepend(
        from distanceFromTop: CGFloat, prepended: Int, rowHeight: CGFloat
    ) -> CGFloat {
        distanceFromTop + CGFloat(max(prepended, 0)) * rowHeight
    }
}
