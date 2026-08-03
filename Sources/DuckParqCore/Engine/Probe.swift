import Foundation

/// One value a column takes, and how many rows carry it.
public struct DistinctValue: Sendable, Equatable, Hashable {
    public let value: String
    public let count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// What a lazily-probed column filter should show.
public enum FilterAffordance: Sendable, Equatable {
    /// Few enough distinct values to pick from a list.
    ///
    /// The values are the column's complete, exact set — not a sample of it —
    /// so there is nothing for the UI to qualify, and the counts are the real
    /// row counts. `nullCount` is how many rows are NULL, zero when none are.
    case dropdown(values: [DistinctValue], nullCount: Int)
    /// Too many distinct values (or the type isn't enumerable) — use operators.
    case comparison
}

/// Schema, counts and cardinality lookups. These run on their own session so a
/// slow grid query never delays a schema panel, and vice versa.
public struct Probe: Sendable {
    /// How many distinct values a column may have and still be picked from a
    /// list rather than typed against.
    ///
    /// The ceiling is about what a person can usefully scan, not about what the
    /// query costs: five hundred station codes or airport identifiers are still
    /// a set you pick from, and the alternative is typing one exactly. The
    /// probe's cost barely moves — the hash table is five hundred groups
    /// instead of fifty — so the screening read is what keeps genuinely
    /// high-cardinality columns from ever reaching the exact question.
    public static let defaultMaxDistinct = 500

    private let session: DuckDBSession

    public init(session: DuckDBSession) {
        self.session = session
    }

    public func columns(of source: DataSource) async throws -> [ColumnInfo] {
        let query = SQLBuilder.describe(source: source)
        let batch = try await session.queryAll(query.sql, params: query.params)
        return (0..<batch.rowCount).compactMap { row in
            guard let name = batch.value(row: row, named: "column_name") else { return nil }
            let type = batch.value(row: row, named: "column_type") ?? "VARCHAR"
            let nullable = (batch.value(row: row, named: "null") ?? "YES").uppercased() != "NO"
            return ColumnInfo(name: name, typeName: type, isNullable: nullable)
        }
    }

    public func rowCount(of source: DataSource, filters: [Filter] = []) async throws -> Int {
        try await count(SQLBuilder.rowCount(source: source, filters: filters))
    }

    /// Run a prepared `count(*)` query. On parquet this is answered largely from
    /// file metadata, so it stays cheap even on files far too large to load.
    public func count(_ query: BoundSQL) async throws -> Int {
        let batch = try await session.queryAll(query.sql, params: query.params, limit: 1)
        guard batch.rowCount > 0, let text = batch[0, 0], let value = Int(text) else { return 0 }
        return value
    }

    /// Decide which filter UI a column deserves, from how many distinct values
    /// it actually has.
    ///
    /// Run when the filter popover opens rather than on file select: probing
    /// every column up front would turn "click a file and look at it" into a
    /// scan per column, which is exactly what this app exists to avoid.
    ///
    /// Two questions, in cost order, and the answer is exact either way:
    ///
    /// 1. **A bounded read of the head.** More than `maxDistinct` values in any
    ///    subset proves more than `maxDistinct` values in the column, so this
    ///    can reject a column outright — cheaply, and without ever being able to
    ///    wrongly admit one. It is a rejection filter, not an estimate.
    /// 2. **The real distinct set**, for whatever survives. `DISTINCT` is a
    ///    blocking hash aggregate, so this reads the column; it is only reached
    ///    for columns that look enumerable, where the hash table stays small and
    ///    parquet's dictionary encoding makes the scan cheap.
    ///
    /// The values shown are therefore the column's, complete. An earlier version
    /// showed the head sample's values directly and labelled them "from the
    /// first 200,000 rows" — which on a column whose early rows are all NULL
    /// meant an empty list, and a caveat in place of the answer.
    public func filterAffordance(
        for column: ColumnInfo,
        in source: DataSource,
        maxDistinct: Int = Probe.defaultMaxDistinct,
        screenRows: Int = 200_000
    ) async throws -> FilterAffordance {
        guard column.kind != .nested, column.kind != .binary else { return .comparison }

        let screen = SQLBuilder.distinctValues(
            source: source, column: column,
            sampleRows: screenRows, maxDistinct: maxDistinct
        )
        let screened = try await session.queryAll(screen.sql, params: screen.params, limit: maxDistinct + 1)
        // One more row than the cap means "too many to enumerate".
        guard screened.rowCount <= maxDistinct else { return .comparison }

        let exact = SQLBuilder.valueCounts(source: source, column: column, maxDistinct: maxDistinct)
        let batch = try await session.queryAll(exact.sql, params: exact.params, limit: maxDistinct + 1)
        guard batch.rowCount <= maxDistinct else { return .comparison }

        var values: [DistinctValue] = []
        var nullCount = 0
        for row in 0..<batch.rowCount {
            let occurrences = Int(batch[row, 1] ?? "") ?? 0
            if let value = batch[row, 0] {
                values.append(DistinctValue(value: value, count: occurrences))
            } else {
                nullCount = occurrences
            }
        }
        // Nothing to choose from is not a dropdown. A column with no values at
        // all is an empty source, and offering an empty list would look exactly
        // like a broken one.
        guard !values.isEmpty || nullCount > 0 else { return .comparison }
        // Alphabetical, not by frequency: a list you are picking from should be
        // in the order you would look something up in, and the counts are right
        // there to be read.
        return .dropdown(values: values.sorted { $0.value < $1.value }, nullCount: nullCount)
    }

    public func fileMetadata(of source: DataSource) async throws -> RowBatch {
        let query = SQLBuilder.fileMetadata(source: source)
        return try await session.queryAll(query.sql, params: query.params, limit: 64)
    }

    public func columnMetadata(of source: DataSource) async throws -> RowBatch {
        let query = SQLBuilder.rowGroupMetadata(source: source)
        return try await session.queryAll(query.sql, params: query.params, limit: 4096)
    }

    public func keyValueMetadata(of source: DataSource) async throws -> RowBatch {
        let query = SQLBuilder.keyValueMetadata(source: source)
        return try await session.queryAll(query.sql, params: query.params, limit: 256)
    }
}
