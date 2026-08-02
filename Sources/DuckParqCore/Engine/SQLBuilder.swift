import Foundation

/// A statement plus the values bound to its `$n` placeholders.
public struct BoundSQL: Sendable, Equatable {
    public let sql: String
    public let params: [String]

    public init(sql: String, params: [String]) {
        self.sql = sql
        self.params = params
    }
}

/// Builds the SQL the grid runs.
///
/// Two rules hold throughout:
///
/// 1. **No user value is ever interpolated into SQL text.** Paths and filter
///    operands become `$n` parameters, bound as VARCHAR and cast at the
///    comparison site — where the column's real type is known from DESCRIBE.
/// 2. **Sorting and filtering are DuckDB's job.** The builder emits `ORDER BY`
///    and `WHERE` against the real typed columns; nothing is reordered locally.
///
/// The source is always aliased `t` and ordering is qualified `t."col"`. That is
/// not decoration: an unqualified `ORDER BY` resolves to an output alias first,
/// so if a projection ever shadows a column name, `ORDER BY score` would sort
/// the *rendered text* — giving 0, 1, 10, 100 instead of 0, 1, 2, 3.
public enum SQLBuilder {
    public static let sourceAlias = "t"

    /// Double-quote an identifier, escaping embedded quotes.
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Qualified reference to a source column: `t."name"`.
    public static func columnRef(_ name: String) -> String {
        "\(sourceAlias).\(quote(name))"
    }

    /// A type usable as a CAST target. DESCRIBE reports types that are already
    /// valid SQL (`BIGINT`, `DECIMAL(18,4)`, `BIGINT[]`), but nested and binary
    /// types are not sensibly comparable to a typed literal, so those fall back
    /// to VARCHAR and compare against the rendered text.
    static func castTarget(for column: ColumnInfo) -> String {
        switch column.kind {
        case .nested, .binary, .other: return "VARCHAR"
        default: return column.typeName
        }
    }

    /// The main grid query: every column, filtered and ordered by DuckDB.
    ///
    /// Deliberately `SELECT *` with no casts — the bridge wraps this in
    /// `SELECT COLUMNS(*)::VARCHAR FROM (...)`, which renders every type
    /// (DECIMAL, LIST, STRUCT, TIMESTAMPTZ, BLOB) correctly and preserves the
    /// inner ordering.
    public static func rows(
        source: DataSource,
        filters: [Filter] = [],
        sort: [SortKey] = []
    ) -> BoundSQL {
        var params: [String] = [source.readPath]
        var sql = "SELECT * FROM \(source.readExpression(parameterIndex: 1)) AS \(sourceAlias)"

        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }

        if !sort.isEmpty {
            let terms = sort.map { "\(columnRef($0.column)) \($0.direction.rawValue)" }
            sql += " ORDER BY " + terms.joined(separator: ", ")
        }

        return BoundSQL(sql: sql, params: params)
    }

    // MARK: - Editable text

    /// The grid's current query as standalone SQL, for handing to the editor.
    ///
    /// Built from the same pieces as `rows(...)` — in particular the same
    /// `predicate(for:params:)` — so what the user is shown is the query that
    /// produced what they are looking at, not a second implementation that can
    /// drift from it. Clauses go on their own lines because this text is meant
    /// to be read and edited.
    public static func editableRows(
        source: DataSource,
        filters: [Filter] = [],
        sort: [SortKey] = []
    ) -> String {
        var params: [String] = [source.readPath]
        var lines = [
            "SELECT *",
            "FROM \(source.readExpression(parameterIndex: 1)) AS \(sourceAlias)",
        ]

        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            lines.append("WHERE " + predicates.joined(separator: "\n  AND "))
        }

        if !sort.isEmpty {
            let terms = sort.map { "\(columnRef($0.column)) \($0.direction.rawValue)" }
            lines.append("ORDER BY " + terms.joined(separator: ", "))
        }

        return inlined(BoundSQL(sql: lines.joined(separator: "\n"), params: params))
    }

    /// `read_parquet('…')` with the path written out, for text handed to the
    /// user — the editor's "Insert Path", the sidebar's copy action.
    public static func readExpression(for source: DataSource) -> String {
        inlined(BoundSQL(sql: source.readExpression(parameterIndex: 1), params: [source.readPath]))
    }

    /// `CREATE OR REPLACE VIEW t AS SELECT * FROM read_parquet('…')`, exposing
    /// the current selection to the SQL editor under a short name.
    ///
    /// The path is written as a literal rather than bound, because there is no
    /// parameterised form to use: DuckDB rejects a prepared CREATE VIEW with
    /// "Unexpected prepared parameter. This type of statement can't be
    /// prepared!". `literal(_:)` doubles embedded quotes, which is what stops a
    /// path containing an apostrophe from closing the string early.
    ///
    /// A plain view, not TEMP: temporary objects belong to the connection that
    /// created them, and the grid queries on a different connection.
    public static func createSourceView(_ source: DataSource, named name: String = sourceAlias) -> String {
        inlined(BoundSQL(
            sql: """
                CREATE OR REPLACE VIEW \(quote(name)) AS \
                SELECT * FROM \(source.readExpression(parameterIndex: 1))
                """,
            params: [source.readPath]
        ))
    }

    /// A single-quoted SQL string literal.
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Substitute `$n` placeholders with quoted literals.
    ///
    /// This is the one place values are written into SQL text, and it exists for
    /// display only: the result is text for a person to read and edit, which
    /// then re-enters the app as user-authored SQL and is parsed and checked
    /// like any other. Queries that actually run still bind their parameters.
    ///
    /// Placeholders inside string literals and quoted identifiers are left
    /// alone — a column legitimately named `total$1` must survive this.
    public static func inlined(_ bound: BoundSQL) -> String {
        guard !bound.params.isEmpty else { return bound.sql }

        var out = ""
        out.reserveCapacity(bound.sql.count + 32)
        var index = bound.sql.startIndex
        var openQuote: Character?

        while index < bound.sql.endIndex {
            let character = bound.sql[index]

            if let quote = openQuote {
                out.append(character)
                if character == quote { openQuote = nil }
                index = bound.sql.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                openQuote = character
                out.append(character)
                index = bound.sql.index(after: index)
                continue
            }

            if character == "$" {
                var digits = ""
                var scan = bound.sql.index(after: index)
                while scan < bound.sql.endIndex, bound.sql[scan].isASCII, bound.sql[scan].isNumber {
                    digits.append(bound.sql[scan])
                    scan = bound.sql.index(after: scan)
                }
                if let position = Int(digits), position >= 1, position <= bound.params.count {
                    out += literal(bound.params[position - 1])
                    index = scan
                    continue
                }
            }

            out.append(character)
            index = bound.sql.index(after: index)
        }

        return out
    }

    /// Wrap an arbitrary query the user typed, applying grid sort on top.
    /// Used by the SQL editor so its results stay sortable by header click.
    public static func sorted(rawSQL: String, sort: [SortKey]) -> String {
        guard !sort.isEmpty else { return rawSQL }
        let trimmed = rawSQL.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r;"))
        let terms = sort.map { "\(quote($0.column)) \($0.direction.rawValue)" }
        return "SELECT * FROM (\(trimmed)) ORDER BY " + terms.joined(separator: ", ")
    }

    static func predicate(for filter: Filter, params: inout [String]) -> String? {
        let reference = columnRef(filter.column.name)
        let castType = castTarget(for: filter.column)

        func bind(_ value: String) -> String {
            params.append(value)
            return "CAST($\(params.count) AS \(castType))"
        }

        switch filter.mode {
        case .anyOf(let values, let includeNull):
            var clauses: [String] = []
            if !values.isEmpty {
                let placeholders = values.sorted().map { bind($0) }
                clauses.append("\(reference) IN (\(placeholders.joined(separator: ", ")))")
            }
            if includeNull {
                clauses.append("\(reference) IS NULL")
            }
            guard !clauses.isEmpty else { return nil }
            return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " OR ") + ")"

        case .comparison(let op, let arguments):
            switch op {
            case .isNull: return "\(reference) IS NULL"
            case .isNotNull: return "\(reference) IS NOT NULL"

            case .between:
                guard arguments.count >= 2 else { return nil }
                return "\(reference) BETWEEN \(bind(arguments[0])) AND \(bind(arguments[1]))"

            case .contains, .startsWith:
                // Function form rather than LIKE, so % and _ in the user's text
                // are literal instead of accidental wildcards.
                guard let needle = arguments.first else { return nil }
                params.append(needle)
                let function = op == .contains ? "contains" : "starts_with"
                return "\(function)(CAST(\(reference) AS VARCHAR), $\(params.count))"

            case .equal, .notEqual, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
                guard let value = arguments.first else { return nil }
                let symbol: String
                switch op {
                case .equal: symbol = "="
                case .notEqual: symbol = "<>"
                case .lessThan: symbol = "<"
                case .lessOrEqual: symbol = "<="
                case .greaterThan: symbol = ">"
                default: symbol = ">="
                }
                return "\(reference) \(symbol) \(bind(value))"
            }
        }
    }

    // MARK: - Probes

    public static func describe(source: DataSource) -> BoundSQL {
        BoundSQL(
            sql: "DESCRIBE SELECT * FROM \(source.readExpression(parameterIndex: 1))",
            params: [source.readPath]
        )
    }

    public static func rowCount(source: DataSource, filters: [Filter] = []) -> BoundSQL {
        var params: [String] = [source.readPath]
        var sql = "SELECT count(*) AS row_count FROM \(source.readExpression(parameterIndex: 1)) AS \(sourceAlias)"
        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }
        return BoundSQL(sql: sql, params: params)
    }

    /// Total rows an arbitrary query would return, so the SQL editor's results
    /// report a total the same way a file selection does.
    public static func rowCount(rawSQL: String) -> BoundSQL {
        let trimmed = rawSQL.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r;"))
        return BoundSQL(sql: "SELECT count(*) AS row_count FROM (\(trimmed))", params: [])
    }

    /// Sample a column's distinct values to decide between a dropdown and a
    /// comparison widget.
    ///
    /// The inner LIMIT is what keeps this fast enough to run on popover open —
    /// it reads the head of the file rather than scanning it. That makes the
    /// result a head-biased sample, which the UI states plainly rather than
    /// implying a full distinct scan.
    public static func distinctValues(
        source: DataSource,
        column: ColumnInfo,
        sampleRows: Int = 200_000,
        maxDistinct: Int = 50
    ) -> BoundSQL {
        let reference = quote(column.name)
        let sql = """
            SELECT CAST(\(reference) AS VARCHAR) AS value, count(*) AS occurrences \
            FROM (SELECT \(reference) FROM \(source.readExpression(parameterIndex: 1)) LIMIT \(sampleRows)) \
            GROUP BY 1 ORDER BY occurrences DESC, value LIMIT \(maxDistinct + 1)
            """
        return BoundSQL(sql: sql, params: [source.readPath])
    }

    // MARK: - Metadata

    public static func fileMetadata(source: DataSource) -> BoundSQL {
        BoundSQL(sql: "SELECT * FROM parquet_file_metadata($1)", params: [source.readPath])
    }

    public static func rowGroupMetadata(source: DataSource) -> BoundSQL {
        let sql = """
            SELECT path_in_schema AS column_name, type, count(*) AS row_groups, \
            sum(num_values) AS values, sum(total_compressed_size) AS compressed_bytes, \
            sum(total_uncompressed_size) AS uncompressed_bytes, \
            any_value(compression) AS compression, min(stats_min_value) AS min_value, \
            max(stats_max_value) AS max_value, sum(stats_null_count) AS nulls \
            FROM parquet_metadata($1) GROUP BY path_in_schema, type ORDER BY column_name
            """
        return BoundSQL(sql: sql, params: [source.readPath])
    }

    public static func keyValueMetadata(source: DataSource) -> BoundSQL {
        BoundSQL(
            sql: "SELECT CAST(key AS VARCHAR) AS key, CAST(value AS VARCHAR) AS value FROM parquet_kv_metadata($1)",
            params: [source.readPath]
        )
    }

    // MARK: - Export

    public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
        case csv = "CSV"
        case tsv = "TSV"
        case parquet = "Parquet"
        case json = "JSON"

        public var id: String { rawValue }

        public var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .tsv: return "tsv"
            case .parquet: return "parquet"
            case .json: return "json"
            }
        }

        var copyOptions: String {
            switch self {
            case .csv: return "FORMAT csv, HEADER"
            case .tsv: return "FORMAT csv, HEADER, DELIMITER '\t'"
            case .parquet: return "FORMAT parquet"
            case .json: return "FORMAT json"
            }
        }
    }

    /// `COPY (<query>) TO <destination>`. The destination is a bound parameter,
    /// and `limit` caps the export to what the user is looking at when they ask
    /// for the current view rather than the whole filtered set.
    public static func export(
        query: BoundSQL,
        to destination: URL,
        format: ExportFormat,
        limit: Int? = nil
    ) -> BoundSQL {
        var params = query.params
        var inner = query.sql
        if let limit {
            inner = "SELECT * FROM (\(inner)) LIMIT \(limit)"
        }
        params.append(destination.path)
        let sql = "COPY (\(inner)) TO $\(params.count) (\(format.copyOptions))"
        return BoundSQL(sql: sql, params: params)
    }
}
