import Foundation

public enum SQLTokenKind: Sendable, Equatable, CaseIterable {
    case keyword
    case identifier
    /// A `"quoted"` identifier. Distinct from `.identifier` because it can never
    /// be a keyword, however much it looks like one.
    case quotedIdentifier
    case stringConstant
    case numericConstant
    case comment
    case `operator`
    /// A token that never terminates — an open `'` or `"` running to end of
    /// input. The DuckDB CLI colours these red, and so do we.
    case error
}

/// A token's extent, in **UTF-16 offsets** so ranges can be handed straight to
/// `NSAttributedString` without conversion.
public struct SQLToken: Sendable, Equatable {
    public let kind: SQLTokenKind
    public let location: Int
    public let length: Int

    public init(kind: SQLTokenKind, location: Int, length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
}

/// A SQL tokenizer for syntax highlighting.
///
/// DuckDB exposes `duckdb_tokenize` in its C API, which is what the CLI's own
/// highlighter uses — but the symbol is absent from the vendored static-library
/// bundle (`nm` finds no `_duckdb_tokenize`), so this reimplements it. The
/// classification is deliberately the same shape as DuckDB's token types, and
/// the keyword set is not guessed: it comes from the engine at runtime via
/// `duckdb_keywords()`. See `SQLKeywords`.
///
/// Highlighting only, never semantics. Nothing here decides what runs — that is
/// `SQLPolicy`, which asks DuckDB's real parser.
public enum SQLSyntax {
    public static func tokenize(_ text: String, keywords: Set<String>) -> [SQLToken] {
        let units = Array(text.utf16)
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(units.count / 4)

        var index = 0
        while index < units.count {
            let start = index
            let unit = units[index]

            if isWhitespace(unit) {
                index += 1
                continue
            }

            // -- line comment
            if unit == .dash, next(units, index) == .dash {
                while index < units.count, units[index] != .newline { index += 1 }
                tokens.append(SQLToken(kind: .comment, location: start, length: index - start))
                continue
            }

            // /* block comment */ — nesting, as DuckDB allows.
            if unit == .slash, next(units, index) == .star {
                index += 2
                var depth = 1
                while index < units.count, depth > 0 {
                    if units[index] == .slash, next(units, index) == .star {
                        depth += 1
                        index += 2
                    } else if units[index] == .star, next(units, index) == .slash {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                tokens.append(SQLToken(kind: .comment, location: start, length: index - start))
                continue
            }

            // 'string' and "identifier" — both double their quote to escape it.
            if unit == .singleQuote || unit == .doubleQuote {
                let terminated = scanQuoted(units, from: &index, quote: unit)
                let kind: SQLTokenKind = terminated
                    ? (unit == .singleQuote ? .stringConstant : .quotedIdentifier)
                    : .error
                tokens.append(SQLToken(kind: kind, location: start, length: index - start))
                continue
            }

            if isDigit(unit) || (unit == .dot && isDigit(next(units, index))) {
                scanNumber(units, from: &index)
                tokens.append(SQLToken(kind: .numericConstant, location: start, length: index - start))
                continue
            }

            if isIdentifierStart(unit) {
                while index < units.count, isIdentifierBody(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                let kind: SQLTokenKind = keywords.contains(word.uppercased()) ? .keyword : .identifier
                tokens.append(SQLToken(kind: kind, location: start, length: index - start))
                continue
            }

            // `::` reads as a keyword in the CLI, unlike every other operator.
            if unit == .colon, next(units, index) == .colon {
                index += 2
                tokens.append(SQLToken(kind: .keyword, location: start, length: 2))
                continue
            }

            index += 1
            tokens.append(SQLToken(kind: .operator, location: start, length: 1))
        }

        return tokens
    }

    // MARK: - Scanning

    /// Consume a quoted run, returning whether it was closed. A doubled quote
    /// (`''`, `""`) is an escape and does not end the run.
    private static func scanQuoted(_ units: [UInt16], from index: inout Int, quote: UInt16) -> Bool {
        index += 1
        while index < units.count {
            if units[index] == quote {
                if next(units, index) == quote {
                    index += 2
                    continue
                }
                index += 1
                return true
            }
            index += 1
        }
        return false
    }

    private static func scanNumber(_ units: [UInt16], from index: inout Int) {
        // Hex, which DuckDB accepts as 0x1F.
        if units[index] == .zero, let after = next(units, index),
           after == .lowerX || after == .upperX {
            index += 2
            while index < units.count, isHexDigit(units[index]) { index += 1 }
            return
        }

        var seenDot = false
        while index < units.count {
            let unit = units[index]
            if isDigit(unit) {
                index += 1
            } else if unit == .dot, !seenDot {
                seenDot = true
                index += 1
            } else {
                break
            }
        }

        // Exponent, only when it is really one: 1e5, 1e+5 — but not the `e` of
        // an identifier that happens to follow a number.
        if index < units.count, units[index] == .lowerE || units[index] == .upperE {
            var lookahead = index + 1
            if lookahead < units.count, units[lookahead] == .plus || units[lookahead] == .minus {
                lookahead += 1
            }
            if lookahead < units.count, isDigit(units[lookahead]) {
                index = lookahead
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
        }
    }

    // MARK: - Character classes

    private static func next(_ units: [UInt16], _ index: Int) -> UInt16? {
        index + 1 < units.count ? units[index + 1] : nil
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    private static func isDigit(_ unit: UInt16?) -> Bool {
        guard let unit else { return false }
        return unit >= .zero && unit <= .nine
    }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit)
            || (unit >= .lowerA && unit <= .lowerF)
            || (unit >= .upperA && unit <= .upperF)
    }

    /// Identifiers may start with a letter, `_`, or anything non-ASCII — a
    /// column named `größe` is an identifier, not a run of operators.
    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= .lowerA && unit <= .lowerZ)
            || (unit >= .upperA && unit <= .upperZ)
            || unit == .underscore
            || unit >= 0x80
    }

    private static func isIdentifierBody(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || unit == .dollar
    }
}

/// ASCII code units, named so the scanner reads as prose rather than numbers.
private extension UInt16 {
    static let newline: UInt16 = 0x0A
    static let dollar: UInt16 = 0x24
    static let singleQuote: UInt16 = 0x27
    static let plus: UInt16 = 0x2B
    static let minus: UInt16 = 0x2D
    static let dash: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let star: UInt16 = 0x2A
    static let doubleQuote: UInt16 = 0x22
    static let colon: UInt16 = 0x3A
    static let underscore: UInt16 = 0x5F
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39
    static let upperA: UInt16 = 0x41
    static let upperE: UInt16 = 0x45
    static let upperF: UInt16 = 0x46
    static let upperX: UInt16 = 0x58
    static let upperZ: UInt16 = 0x5A
    static let lowerA: UInt16 = 0x61
    static let lowerE: UInt16 = 0x65
    static let lowerF: UInt16 = 0x66
    static let lowerX: UInt16 = 0x78
    static let lowerZ: UInt16 = 0x7A
}
