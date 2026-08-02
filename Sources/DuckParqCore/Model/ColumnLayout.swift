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
}
