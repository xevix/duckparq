import AppKit
import DuckParqCore

/// Turns `SQLPalette` — the DuckDB CLI's colours, defined and tested in the
/// core module — into AppKit colours and fonts.
///
/// Deliberately mechanical. All the judgement, and the provenance of the
/// values, lives in `SQLPalette`.
enum SQLTheme {
    static func nsColor(_ color: SQLColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// The colour for a token, or nil to leave it at the editor's text colour.
    static func color(for kind: SQLTokenKind, in palette: SQLPalette) -> NSColor? {
        palette.color(for: kind).map(nsColor)
    }

    static func isBold(_ kind: SQLTokenKind, in palette: SQLPalette) -> Bool {
        palette.color(for: kind)?.isBold ?? false
    }
}
