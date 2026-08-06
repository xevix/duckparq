import Foundation

/// Column sizing for the grid.
///
/// There is deliberately one entry point that returns **all** widths at once.
/// The header and the rows are separate views, and when each derived its own
/// widths they could disagree — which showed up as data sitting under the wrong
/// headers. Both now render from the single array this returns.
public enum ColumnLayout {
    public static let minWidth: CGFloat = 62
    public static let maxWidth: CGFloat = 420
    /// Rows sampled when measuring. The grid pages, so this looks at what is on
    /// screen rather than the whole result.
    public static let sampleRows = 80

    /// Approximate width of one character in the grid's monospaced font.
    /// Monospacing is what makes character counting a fair proxy for width and
    /// avoids laying out every cell just to measure it.
    static let characterWidth: CGFloat = 7.3
    static let horizontalPadding: CGFloat = 18
    /// Room for the sort chevron and ordinal badge in the header.
    static let headerAffordance = 3

    /// One width per column, positionally aligned with `columns`.
    ///
    /// Positional, not keyed by name: parquet files can contain duplicate or
    /// empty column names, and a name-keyed lookup would collapse them and shift
    /// every column after the collision.
    public static func widths(
        for columns: [ColumnInfo],
        rows: [TableModel.GridRow],
        overrides: [String: CGFloat] = [:]
    ) -> [CGFloat] {
        columns.enumerated().map { index, column in
            if let override = overrides[column.name] {
                return clamp(override)
            }
            return estimatedWidth(for: column, rows: rows, index: index)
        }
    }

    public static func estimatedWidth(
        for column: ColumnInfo,
        rows: [TableModel.GridRow],
        index: Int
    ) -> CGFloat {
        var longest = column.name.count + headerAffordance
        for row in rows.prefix(sampleRows) where index < row.cells.count {
            // NULL renders as the literal text "NULL", so it needs room too.
            longest = max(longest, (row.cells[index] ?? "NULL").count)
        }
        return clamp(CGFloat(longest) * characterWidth + horizontalPadding)
    }

    public static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }

    // MARK: - Horizontal virtualization

    /// Running x positions for `widths`: `offsets[i]` is where column `i`
    /// starts, and the last entry is the total width.
    ///
    /// Computed once per width change and reused by every row, which is what
    /// makes finding the visible columns a binary search rather than a scan.
    public static func offsets(for widths: [CGFloat]) -> [CGFloat] {
        var offsets = [CGFloat](repeating: 0, count: widths.count + 1)
        var x: CGFloat = 0
        for (index, width) in widths.enumerated() {
            x += width
            offsets[index + 1] = x
        }
        return offsets
    }

    /// The columns that intersect the viewport `[x, x + width)`, widened by
    /// `overscan` columns on each side.
    ///
    /// A grid of a thousand columns draws a dozen of them; building views for
    /// the rest costs seconds per screenful and shows nobody anything. The
    /// overscan is what keeps a fast horizontal flick from exposing blank
    /// columns before the next render catches up.
    public static func visibleRange(
        offsets: [CGFloat],
        x: CGFloat,
        width: CGFloat,
        overscan: Int = 3
    ) -> Range<Int> {
        let count = offsets.count - 1
        guard count > 0, width > 0 else { return 0..<0 }

        let left = max(x, 0)
        let right = left + width
        // A column is on screen when its span overlaps the viewport. Both edges
        // are half-open, so a column that ends exactly where the viewport
        // begins is out and one that starts exactly where it ends is too —
        // otherwise the range grows by a column at every scroll position that
        // happens to land on a boundary.
        let first = firstIndex(in: offsets, where: { $0 > left }, from: 1) - 1
        let end = firstIndex(in: offsets, where: { $0 >= right }, from: 0)

        let lower = max(first - overscan, 0)
        let upper = min(end + overscan, count)
        return lower..<max(upper, lower)
    }

    /// Which column covers `x`, clamped to the ends. This is how a row turns a
    /// pointer position back into a cell now that the cells are drawn rather
    /// than laid out as views that could be hit-tested.
    public static func columnIndex(offsets: [CGFloat], at x: CGFloat) -> Int? {
        let count = offsets.count - 1
        guard count > 0 else { return nil }
        return min(max(firstIndex(in: offsets, where: { $0 > x }, from: 1) - 1, 0), count - 1)
    }

    /// The first index at or after `start` whose offset satisfies `predicate`,
    /// or `offsets.count - 1` if none does. `offsets` is sorted, so this is a
    /// binary search — which is what keeps finding the visible columns
    /// independent of how many there are.
    private static func firstIndex(
        in offsets: [CGFloat],
        where predicate: (CGFloat) -> Bool,
        from start: Int
    ) -> Int {
        var low = start
        var high = offsets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if predicate(offsets[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
