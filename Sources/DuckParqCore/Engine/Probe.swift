import Foundation

/// What a lazily-probed column filter should show.
public enum FilterAffordance: Sendable, Equatable {
    /// Few enough distinct values to pick from a list. `hasNull` reports whether
    /// NULL appeared in the sample.
    case dropdown(values: [String], hasNull: Bool, sampled: Bool)
    /// Too many distinct values (or the type isn't enumerable) — use operators.
    case comparison
}

/// Schema, counts and cardinality lookups. These run on their own session so a
/// slow grid query never delays a schema panel, and vice versa.
public struct Probe: Sendable {
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

    /// Decide which filter UI a column deserves, by sampling its distinct values.
    ///
    /// Run when the filter popover opens rather than on file select: probing
    /// every column up front would turn "click a file and look at it" into a
    /// full scan per column, which is exactly what this app exists to avoid.
    public func filterAffordance(
        for column: ColumnInfo,
        in source: DataSource,
        maxDistinct: Int = 50,
        sampleRows: Int = 200_000
    ) async throws -> FilterAffordance {
        guard column.kind != .nested, column.kind != .binary else { return .comparison }

        let query = SQLBuilder.distinctValues(
            source: source, column: column,
            sampleRows: sampleRows, maxDistinct: maxDistinct
        )
        let batch = try await session.queryAll(query.sql, params: query.params, limit: maxDistinct + 1)

        // One more row than the cap means "too many to enumerate".
        guard batch.rowCount <= maxDistinct else { return .comparison }

        var values: [String] = []
        var hasNull = false
        for row in 0..<batch.rowCount {
            if let value = batch[row, 0] {
                values.append(value)
            } else {
                hasNull = true
            }
        }

        let total = try? await rowCount(of: source)
        let sampled = (total ?? Int.max) > sampleRows
        return .dropdown(values: values.sorted(), hasNull: hasNull, sampled: sampled)
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
