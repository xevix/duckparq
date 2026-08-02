import Foundation

/// A comparison a column filter can apply. `contains`/`startsWith` are text-only;
/// the ordered comparisons are offered for numbers, dates and times.
public enum FilterOperator: String, Sendable, Hashable, CaseIterable, Identifiable {
    case equal = "="
    case notEqual = "≠"
    case lessThan = "<"
    case lessOrEqual = "≤"
    case greaterThan = ">"
    case greaterOrEqual = "≥"
    case between = "between"
    case contains = "contains"
    case startsWith = "starts with"
    case isNull = "is null"
    case isNotNull = "is not null"

    public var id: String { rawValue }

    public var argumentCount: Int {
        switch self {
        case .isNull, .isNotNull: return 0
        case .between: return 2
        default: return 1
        }
    }

    public static func available(for kind: ColumnKind) -> [FilterOperator] {
        // Nested and binary columns compare against their rendered text, where
        // equality is misleading and ordering is meaningless — offer presence
        // checks plus a substring search over the rendering, nothing more.
        if kind == .nested || kind == .binary {
            return [.contains, .isNull, .isNotNull]
        }
        var operators: [FilterOperator] = [.equal, .notEqual]
        if kind.isOrdered {
            operators += [.lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual, .between]
        }
        if kind == .text {
            operators += [.contains, .startsWith]
        }
        operators += [.isNull, .isNotNull]
        return operators
    }
}

/// One filter chip. Either a set-membership filter (low-cardinality dropdown) or
/// a comparison; both compile to a `WHERE` predicate on the real typed column.
public struct Filter: Sendable, Hashable, Identifiable {
    public enum Mode: Sendable, Hashable {
        /// Multi-select dropdown, offered when a column turns out to be low
        /// cardinality. `nil` inside the set represents SQL NULL.
        case anyOf(Set<String>, includeNull: Bool)
        case comparison(FilterOperator, [String])
    }

    public let id: UUID
    public var column: ColumnInfo
    public var mode: Mode
    public var isEnabled: Bool

    public init(id: UUID = UUID(), column: ColumnInfo, mode: Mode, isEnabled: Bool = true) {
        self.id = id
        self.column = column
        self.mode = mode
        self.isEnabled = isEnabled
    }

    /// True when the filter has everything it needs to be applied. Half-typed
    /// filters are held in the UI without being sent to DuckDB.
    public var isComplete: Bool {
        switch mode {
        case .anyOf(let values, let includeNull):
            return !values.isEmpty || includeNull
        case .comparison(let op, let arguments):
            guard arguments.count >= op.argumentCount else { return false }
            return arguments.prefix(op.argumentCount).allSatisfy { !$0.isEmpty }
        }
    }

    public var summary: String {
        switch mode {
        case .anyOf(let values, let includeNull):
            var parts = values.sorted()
            if includeNull { parts.append("NULL") }
            let shown = parts.prefix(3).joined(separator: ", ")
            let extra = parts.count > 3 ? " +\(parts.count - 3)" : ""
            return "\(column.name) in \(shown)\(extra)"
        case .comparison(let op, let arguments):
            switch op {
            case .isNull, .isNotNull:
                return "\(column.name) \(op.rawValue)"
            case .between:
                let low = arguments.first ?? ""
                let high = arguments.count > 1 ? arguments[1] : ""
                return "\(column.name) between \(low) and \(high)"
            default:
                return "\(column.name) \(op.rawValue) \(arguments.first ?? "")"
            }
        }
    }
}

/// How a column is sorted. Clicking a header cycles through these, and each
/// transition re-runs the query with a new ORDER BY — the grid never reorders
/// rows it has already loaded.
public enum SortDirection: String, Sendable, Hashable {
    case ascending = "ASC"
    case descending = "DESC"
}

public struct SortKey: Sendable, Hashable, Identifiable {
    public let column: String
    public var direction: SortDirection

    public var id: String { column }

    public init(column: String, direction: SortDirection) {
        self.column = column
        self.direction = direction
    }
}
