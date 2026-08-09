import Foundation

/// Which row the up and down arrows move to once a row is selected.
///
/// Selecting a row changes what the arrow keys are for. With nothing selected
/// the grid is a picture and the arrows move the view over it — see
/// `GridScroll.arrow`. With a row selected it is a list, and the arrows move
/// through it, the way they do in every other list on the platform.
///
/// The arithmetic is one addition; its edges are the reason this is a type. The
/// ends the selection runs into are the ends of the *loaded window*, which are
/// not the ends of the result — so a step off the top is a request for rows
/// rather than a refusal, and the caller has to be told which of the two it is
/// getting.
public enum GridSelection {
    /// Which way an arrow press moves the selection. Named apart from
    /// `GridScroll.ArrowDirection` because only two of its four cases mean
    /// anything here: left and right move the columns, and moving the columns
    /// has nothing to say about which row is selected.
    public enum Step: Sendable, Equatable {
        case up
        case down
    }

    /// What a press comes to.
    public enum Move: Sendable, Equatable {
        /// Select this row id, and bring it into view.
        case select(Int)
        /// The selection is on the first loaded row and the window does not
        /// begin at the start of the result: there is a row above, it just is
        /// not here yet. The press asks for it and leaves the selection alone,
        /// so a second press moves onto the rows that arrive.
        case loadEarlier
        /// Nowhere to go: the first row of the whole result going up, or the
        /// last loaded row going down.
        case stay
    }

    /// Where a press takes the selection.
    ///
    /// `selected` and the answer are row ids — offsets into the whole result —
    /// so they are compared against `windowStart` rather than treated as
    /// positions in `rows`.
    ///
    /// Going down stops at the last loaded row instead of asking for more, and
    /// the asymmetry with `loadEarlier` is in the model rather than here:
    /// forward paging is driven by rows *appearing*, so a selection that reaches
    /// the bottom of the window has already realised the row that asks for the
    /// next page. Backward paging has no such trigger — a `LazyVStack` fills
    /// from the top, so rows appearing there say nothing about where the user
    /// is — and must be asked for outright.
    public static func move(
        _ step: Step,
        from selected: Int,
        windowStart: Int,
        loadedRows: Int
    ) -> Move {
        guard loadedRows > 0 else { return .stay }
        let first = windowStart
        let last = windowStart + loadedRows - 1

        // A selection outside the loaded window is a row that has been paged
        // away from under it — a jump to the end leaves one behind at row 3 of
        // three billion. The press means "move from here", and the nearest
        // loaded row is the only honest reading of where "here" now is.
        guard selected >= first, selected <= last else {
            return .select(min(max(selected, first), last))
        }

        switch step {
        case .up:
            guard selected > first else { return windowStart > 0 ? .loadEarlier : .stay }
            return .select(selected - 1)
        case .down:
            guard selected < last else { return .stay }
            return .select(selected + 1)
        }
    }
}
