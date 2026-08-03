import Foundation

/// Re-indents SQL for reading.
///
/// **Only whitespace moves.** The formatter re-emits the exact text of every
/// token the tokenizer produced, in the same order, and changes nothing else —
/// no case folding, no rewriting of literals, no reordering, no clause it
/// decided it understood better than you did. Re-tokenizing the output has to
/// yield the identical sequence of token texts, which is what the suite checks
/// against every sample it formats.
///
/// That invariant is the whole reason this is safe to hang off a button beside a
/// query you are about to run. A formatter that parses SQL and regenerates it
/// can quietly change meaning on syntax it half-understands; this one cannot,
/// because it never regenerates anything.
///
/// It shares `SQLSyntax`'s tokenizer with the highlighter, so the two agree
/// about what a string literal is — a `--` inside quotes is text, not a comment,
/// to both of them.
public enum SQLFormatter {
    public static let indentUnit = "  "

    /// Keywords that begin a new line at the current nesting level.
    private static let clauseStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET",
        "WINDOW", "QUALIFY", "UNION", "INTERSECT", "EXCEPT", "VALUES", "WITH",
        "RETURNING", "PIVOT", "UNPIVOT", "FETCH",
    ]

    /// Clauses whose items are a comma-separated list worth breaking apart.
    private static let listClauses: Set<String> = ["SELECT", "FROM", "GROUP", "ORDER", "RETURNING"]

    /// Keywords that start a join line. `LEFT OUTER JOIN` is one line, not
    /// three, so a run of these stays together.
    private static let joinStarters: Set<String> = [
        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL",
        "ANTI", "SEMI", "POSITIONAL", "ASOF",
    ]

    /// Keywords after which a `(` opens a subquery rather than a call.
    private static let blockParenFollowers: Set<String> = ["SELECT", "WITH", "VALUES", "FROM", "TABLE"]

    /// State that nests with subquery parentheses, so a `SELECT a, b` inside a
    /// subquery breaks its own list without disturbing the enclosing one.
    private struct Frame {
        /// The current clause is a list, so commas end lines.
        var breaksOnComma = false
        /// Depth of ordinary (non-subquery) parens — a comma inside `f(a, b)`
        /// belongs to the call, not to the clause.
        var callParens = 0
        /// Pending `BETWEEN`s, whose `AND` must stay on the line.
        var pendingBetween = 0
        var caseDepth = 0
        var inJoin = false
    }

    public static func format(_ sql: String, keywords: Set<String> = SQLKeywords.shared.all) -> String {
        let units = Array(sql.utf16)
        let tokens = SQLSyntax.tokenize(sql, keywords: keywords)
        guard !tokens.isEmpty else { return sql.trimmingCharacters(in: .whitespacesAndNewlines) }

        func text(_ token: SQLToken) -> String {
            String(decoding: units[token.location..<token.end], as: UTF16.self)
        }

        var out = ""
        out.reserveCapacity(sql.count + sql.count / 4)
        var atLineStart = true
        var depth = 0
        var frames = [Frame()]
        /// One entry per open paren: true when it opened a subquery.
        var openParens: [Bool] = []
        /// An indent level to break to before the next token, if any.
        var pendingBreak: Int?
        /// Set by a token that must stay glued to whatever follows it — `$` of
        /// `$1`, the `-` of a negative literal, a cast's `::`.
        var glueToNext = false
        var previousPiece = ""

        func newline(_ level: Int) {
            if !out.isEmpty { out += "\n" }
            out += String(repeating: indentUnit, count: max(level, 0))
            atLineStart = true
        }

        /// Joining without a separator must never invent a token: `-` then `-`
        /// would become a line comment and swallow the rest of the line.
        func wouldMerge(_ left: Character, _ right: Character) -> Bool {
            (left == "-" && right == "-") || (left == "/" && right == "*") || (left == "*" && right == "/")
        }

        func emit(_ piece: String, spaced: Bool) {
            guard let first = piece.first else { return }
            if atLineStart {
                out += piece
                atLineStart = false
                return
            }
            if spaced {
                out += " "
            } else if let last = out.last, wouldMerge(last, first) {
                out += " "
            }
            out += piece
        }

        for (index, token) in tokens.enumerated() {
            let piece = text(token)
            let word = token.kind == .keyword ? piece.uppercased() : ""
            let previous = index > 0 ? tokens[index - 1] : nil
            let nextToken = index + 1 < tokens.count ? tokens[index + 1] : nil
            let nextText = nextToken.map(text)

            var breakBefore = false
            var breakLevel = depth
            var spaced = true
            /// This token is a clause heading whose list starts on the next
            /// line. Applied after it is emitted — setting `pendingBreak` here
            /// would be consumed by the token's own line break.
            var opensList = false

            if glueToNext { spaced = false }
            glueToNext = false

            // Two operator characters the source wrote adjacent are one operator
            // as far as the parser is concerned — `<=`, `!=`, `->`, `||`, `))`.
            // Splitting them is the one way whitespace alone can break a query.
            if let previous, previous.end == token.location,
               previous.kind == .operator, token.kind == .operator,
               previousPiece != ",", previousPiece != ";" {
                spaced = false
            }

            if previousPiece == "(" || previousPiece == "[" { spaced = false }
            if piece == "," || piece == ";" || piece == ")" || piece == "]" { spaced = false }
            if piece == "." || previousPiece == "." { spaced = false }
            // `count(` and `a[` are calls and subscripts; `IN (` keeps its space.
            if piece == "(" || piece == "[" {
                switch previous?.kind {
                case .identifier, .quotedIdentifier: spaced = false
                default: if previousPiece == ")" || previousPiece == "]" { spaced = false }
                }
            }
            if piece == "::" { spaced = false }

            switch token.kind {
            case .keyword:
                let followedByParen = nextText == "("
                if joinStarters.contains(word), !followedByParen {
                    // Only the first keyword of the run opens the line.
                    if !joinStarters.contains(previousPiece.uppercased()) {
                        breakBefore = true
                        frames[frames.count - 1].breaksOnComma = false
                    }
                    frames[frames.count - 1].inJoin = true
                } else if clauseStarters.contains(word) {
                    breakBefore = true
                    frames[frames.count - 1].breaksOnComma = listClauses.contains(word)
                    frames[frames.count - 1].inJoin = false
                    // A `SELECT` with more than one item reads better as a
                    // heading over its list than as one long line.
                    if word == "SELECT",
                       topLevelCommaFollows(tokens, from: index, units: units) {
                        opensList = true
                    }
                } else if word == "ON", frames[frames.count - 1].inJoin {
                    breakBefore = true
                    breakLevel = depth + 1
                } else if word == "AND" || word == "OR" {
                    if word == "AND", frames[frames.count - 1].pendingBetween > 0 {
                        // The `AND` of `BETWEEN x AND y` is not a conjunction.
                        frames[frames.count - 1].pendingBetween -= 1
                    } else if frames[frames.count - 1].callParens == 0 {
                        breakBefore = true
                        breakLevel = depth + 1
                    }
                } else if word == "WHEN" || word == "ELSE", frames[frames.count - 1].caseDepth > 0 {
                    breakBefore = true
                    breakLevel = depth + 1
                }

                if word == "BETWEEN" { frames[frames.count - 1].pendingBetween += 1 }
                if word == "CASE" { frames[frames.count - 1].caseDepth += 1 }
                if word == "END", frames[frames.count - 1].caseDepth > 0 {
                    frames[frames.count - 1].caseDepth -= 1
                }
                if piece == "::" { glueToNext = true }

            case .operator:
                if piece == "(" {
                    let opensBlock = nextToken?.kind == .keyword
                        && blockParenFollowers.contains((nextText ?? "").uppercased())
                    openParens.append(opensBlock)
                    if opensBlock {
                        frames.append(Frame())
                        depth += 1
                    } else {
                        frames[frames.count - 1].callParens += 1
                    }
                } else if piece == ")" {
                    let closesBlock = openParens.popLast() ?? false
                    if closesBlock {
                        if frames.count > 1 { frames.removeLast() }
                        depth = max(depth - 1, 0)
                        breakBefore = true
                        breakLevel = depth
                    } else {
                        frames[frames.count - 1].callParens =
                            max(frames[frames.count - 1].callParens - 1, 0)
                    }
                } else if piece == "$" {
                    // `$1` is one placeholder in two tokens.
                    glueToNext = true
                } else if piece == "-" || piece == "+" {
                    // A sign is unary when nothing to its left could be its left
                    // operand. Spacing never changes what `-` means, so this is
                    // cosmetic — but `- 1` where the source said `-1` reads as a
                    // mistake.
                    let unary: Bool
                    switch previous?.kind {
                    case .none: unary = true
                    case .keyword: unary = previousPiece != "END"
                    case .operator: unary = previousPiece != ")" && previousPiece != "]"
                    default: unary = false
                    }
                    if unary { glueToNext = true }
                }

            default:
                break
            }

            if breakBefore || pendingBreak != nil {
                newline(breakBefore ? breakLevel : (pendingBreak ?? depth))
                pendingBreak = nil
                glueToNext = false
            }
            emit(piece, spaced: spaced)
            previousPiece = piece

            if opensList { pendingBreak = depth + 1 }
            // A `(` that opened a subquery puts its contents on the next line.
            if token.kind == .operator, piece == "(", openParens.last == true {
                pendingBreak = depth
            }
            if token.kind == .operator, piece == "," {
                let frame = frames[frames.count - 1]
                if frame.breaksOnComma, frame.callParens == 0 {
                    pendingBreak = depth + 1
                }
            }
            if token.kind == .operator, piece == ";" { pendingBreak = depth }
            // Everything after a `--` on the same line would be inside it.
            if token.kind == .comment, piece.hasPrefix("--") { pendingBreak = depth }
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the clause starting at `index` has more than one item — a comma
    /// at this nesting level before the next clause keyword.
    private static func topLevelCommaFollows(
        _ tokens: [SQLToken],
        from index: Int,
        units: [UInt16]
    ) -> Bool {
        var parens = 0
        var cursor = index + 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            let piece = String(decoding: units[token.location..<token.end], as: UTF16.self)
            if token.kind == .operator {
                if piece == "(" { parens += 1 }
                if piece == ")" {
                    if parens == 0 { return false }
                    parens -= 1
                }
                if parens == 0, piece == "," { return true }
                if parens == 0, piece == ";" { return false }
            }
            if parens == 0, token.kind == .keyword, clauseStarters.contains(piece.uppercased()) {
                return false
            }
            cursor += 1
        }
        return false
    }
}
