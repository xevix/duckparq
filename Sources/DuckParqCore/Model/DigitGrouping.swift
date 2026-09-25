import Foundation

/// Which numeric columns the user has turned thousands separators off for, in
/// the form that survives a quit.
///
/// Keyed by column name alone, not by file: turning separators off for `year`
/// is a statement about what a `year` is, so it holds in every file and query
/// that has one. Everything not in the set keeps the default, which is grouped.
public struct DigitGrouping {
    public static let defaultsKey = "dev.xevix.duckparq.ungroupedColumns"

    public private(set) var ungrouped: Set<String>
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ungrouped = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Whether `column` is drawn with thousands separators.
    public func groups(_ column: ColumnInfo) -> Bool {
        column.kind.isNumeric && !ungrouped.contains(column.name)
    }

    /// Flips `name` between grouped and not, and saves the result.
    public mutating func toggle(_ name: String) {
        if ungrouped.remove(name) == nil { ungrouped.insert(name) }
        // Sorted so the saved form does not churn with set ordering. Nothing
        // saved at all when nothing is turned off, which is the default.
        if ungrouped.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(ungrouped.sorted(), forKey: Self.defaultsKey)
        }
    }
}
