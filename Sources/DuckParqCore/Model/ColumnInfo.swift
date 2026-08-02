import Foundation

/// How a column should be presented and filtered. Derived from the DuckDB type
/// name reported by DESCRIBE — the grid itself only ever sees text, so this is
/// the sole source of type knowledge in the UI.
public enum ColumnKind: String, Sendable, Hashable {
    case integer, decimal, floating, boolean, text, date, timestamp, time, binary, nested, other

    public var isNumeric: Bool {
        switch self {
        case .integer, .decimal, .floating: return true
        default: return false
        }
    }

    /// Types with a meaningful `<` / `>` ordering, so they get comparison filters.
    public var isOrdered: Bool {
        switch self {
        case .integer, .decimal, .floating, .date, .timestamp, .time: return true
        default: return false
        }
    }

    /// Numbers, dates and times read better right-aligned.
    public var prefersTrailingAlignment: Bool { isOrdered }
}

public struct ColumnInfo: Sendable, Hashable, Identifiable {
    public let name: String
    /// The DuckDB type as DESCRIBE reports it, e.g. `DECIMAL(18,4)`, `BIGINT[]`.
    public let typeName: String
    public let isNullable: Bool

    public var id: String { name }
    public var kind: ColumnKind { ColumnInfo.kind(forType: typeName) }

    public init(name: String, typeName: String, isNullable: Bool = true) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
    }

    public static func kind(forType rawType: String) -> ColumnKind {
        let type = rawType.uppercased()

        // Nested types are checked first: BIGINT[] and STRUCT(a BIGINT) both
        // contain a scalar type name but neither is scalar.
        if type.hasSuffix("]") || type.hasPrefix("STRUCT") || type.hasPrefix("MAP")
            || type.hasPrefix("UNION") || type.hasPrefix("LIST") {
            return .nested
        }
        if type.hasPrefix("DECIMAL") || type.hasPrefix("NUMERIC") { return .decimal }
        if type.hasPrefix("TIMESTAMP") || type == "DATETIME" { return .timestamp }
        if type.hasPrefix("TIME") { return .time }
        if type == "DATE" { return .date }
        if type == "BOOLEAN" || type == "BOOL" { return .boolean }
        if type == "BLOB" || type == "BYTEA" || type == "BINARY" || type == "VARBINARY" {
            return .binary
        }
        if type == "FLOAT" || type == "DOUBLE" || type == "REAL" { return .floating }
        if type.hasSuffix("INT") || type.hasPrefix("INT") || type == "HUGEINT"
            || type == "UHUGEINT" || type == "SIGNED" {
            return .integer
        }
        if type == "VARCHAR" || type == "TEXT" || type == "STRING" || type.hasPrefix("ENUM")
            || type == "UUID" || type == "CHAR" {
            return .text
        }
        return .other
    }
}
