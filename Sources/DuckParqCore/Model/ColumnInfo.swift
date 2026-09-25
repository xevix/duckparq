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

/// How numbers are shown in the grid: with the integer part grouped in
/// thousands, so `1234567.5` reads as `1,234,567.5`.
///
/// Display only. The cells keep DuckDB's own text, so copying a value or
/// filtering on it uses the number exactly as stored — a grouped `1,234` would
/// not parse back as the number it came from.
public enum NumberDisplay {
    public static let separator: Character = ","

    /// `value` with its integer digits grouped, or `value` unchanged when it
    /// is not a plain decimal number — `inf`, `NaN` and exponent forms such as
    /// `1.5e+20` are left as DuckDB wrote them.
    public static func grouped(_ value: String) -> String {
        guard let parts = split(value), parts.digits.count > 3 else { return value }
        var result = String(parts.sign)
        result.reserveCapacity(value.count + parts.digits.count / 3)
        let leading = parts.digits.count % 3
        for (offset, digit) in parts.digits.enumerated() {
            if offset > 0, (offset - leading) % 3 == 0 { result.append(separator) }
            result.append(digit)
        }
        result.append(contentsOf: parts.rest)
        return result
    }

    /// How many characters `grouped(value)` would be, without building it.
    /// Column measurement asks this of every sampled cell.
    public static func groupedCount(_ value: String) -> Int {
        guard let parts = split(value) else { return value.count }
        return value.count + (parts.digits.count - 1) / 3
    }

    /// The sign, the integer digits and everything from the decimal point on,
    /// or nil if `value` is not `[+-]digits[.digits]`.
    private static func split(_ value: String) -> (sign: Substring, digits: Substring, rest: Substring)? {
        let utf8 = value.utf8
        var start = utf8.startIndex
        if let first = utf8.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
            start = utf8.index(after: start)
        }
        var point = start
        while point < utf8.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(utf8[point]) {
            point = utf8.index(after: point)
        }
        guard point > start else { return nil }
        if point < utf8.endIndex {
            guard utf8[point] == UInt8(ascii: ".") else { return nil }
            let fraction = utf8[utf8.index(after: point)...]
            guard fraction.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        }
        return (value[..<start], value[start..<point], value[point...])
    }
}
