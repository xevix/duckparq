import Foundation

/// One syntax colour, carrying the xterm-256 index it came from.
///
/// Keeping the index alongside the RGB is what lets the test suite check this
/// palette against escape sequences captured from the real `duckdb` CLI, rather
/// than trusting a comment that says the colours match.
public struct SQLColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    /// The xterm-256 index the CLI emits for this role, where it uses one.
    public let xtermIndex: Int?
    /// The SGR parameters the CLI writes for this role — "1;38;5;33" for a bold
    /// cube colour, "90" for ANSI bright black. This is what the suite compares
    /// against sequences captured from the real CLI.
    public let ansi: String?
    public let isBold: Bool

    public init(xterm index: Int, bold: Bool = false) {
        let (red, green, blue) = SQLColor.rgb(forXterm: index)
        self.red = red
        self.green = green
        self.blue = blue
        self.xtermIndex = index
        self.ansi = bold ? "1;38;5;\(index)" : "38;5;\(index)"
        self.isBold = bold
    }

    /// A colour with concrete RGB, used where the CLI names a colour the
    /// terminal profile defines and so has no fixed value to copy. `ansi`
    /// records which sequence it stands in for.
    public init(red: Double, green: Double, blue: Double, ansi: String?, bold: Bool = false) {
        self.red = red
        self.green = green
        self.blue = blue
        self.xtermIndex = nil
        self.ansi = ansi
        self.isBold = bold
    }

    /// The xterm-256 palette: 16–231 form a 6×6×6 colour cube, 232–255 a grey
    /// ramp. Only the cube is needed here.
    public static func rgb(forXterm index: Int) -> (Double, Double, Double) {
        let levels: [Double] = [0, 95, 135, 175, 215, 255]
        guard index >= 16, index <= 231 else { return (0, 0, 0) }
        let offset = index - 16
        let red = levels[offset / 36]
        let green = levels[(offset % 36) / 6]
        let blue = levels[offset % 6]
        return (red / 255, green / 255, blue / 255)
    }
}

/// The DuckDB CLI's syntax colours, transcribed from the CLI itself.
///
/// Captured from `duckdb` v1.5.5 — the version DuckParq vendors — by driving it
/// under a pty and reading the escape sequences it writes while highlighting:
///
///     ESC[1m ESC[38;5;33m SELECT  ESC[00m ESC[38;5;220m'abc' ESC[00m
///     ESC[38;5;212m42 ESC[00m ... ESC[90m-- note ESC[00m
///
/// The CLI chooses between two palettes by asking the terminal for its
/// background colour; DuckParq asks the window's appearance instead. The split
/// is not cosmetic — dark mode's gold and pink are illegible on white, which is
/// why DuckDB ships a second set at all.
///
/// Two deliberate departures, both because this is an editor rather than a
/// prompt. Comments use a fixed grey: the CLI emits bright black (`ESC[90m`),
/// whose actual colour is whatever the terminal profile says. And block
/// comments are grey here, where the CLI leaves them uncoloured — DuckDB's
/// tokenizer emits no token for them, and an unhighlighted `/* … */` spanning
/// several lines of an editor reads as an oversight.
public struct SQLPalette: Sendable {
    public let keyword: SQLColor
    public let stringConstant: SQLColor
    public let numericConstant: SQLColor
    public let comment: SQLColor
    public let error: SQLColor
    /// Identifiers and operators, which the CLI leaves at the default colour.
    public let plain: SQLColor?

    public static let dark = SQLPalette(
        keyword: SQLColor(xterm: 33, bold: true),
        stringConstant: SQLColor(xterm: 220),
        numericConstant: SQLColor(xterm: 212),
        comment: SQLColor(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, ansi: "90"),
        error: SQLColor(xterm: 203),
        plain: nil
    )

    public static let light = SQLPalette(
        keyword: SQLColor(xterm: 27, bold: true),
        stringConstant: SQLColor(xterm: 58),
        numericConstant: SQLColor(xterm: 90),
        comment: SQLColor(red: 0x6C / 255, green: 0x6C / 255, blue: 0x70 / 255, ansi: "90"),
        error: SQLColor(xterm: 124),
        plain: nil
    )

    public static func palette(dark isDark: Bool) -> SQLPalette { isDark ? dark : light }

    /// Exhaustive by construction: a new token kind will not compile until it
    /// has been given a colour. `nil` means "leave at the default colour".
    public func color(for kind: SQLTokenKind) -> SQLColor? {
        switch kind {
        case .keyword: return keyword
        case .stringConstant: return stringConstant
        case .numericConstant: return numericConstant
        case .comment: return comment
        case .error: return error
        case .identifier, .quotedIdentifier, .operator: return plain
        }
    }
}
