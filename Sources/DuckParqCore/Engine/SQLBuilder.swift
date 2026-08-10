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
    ///
    /// `tiebreak` appends the source's `rowIdentityColumns` to the ORDER BY in
    /// that direction — see `tiebreakingOrder`. Nil leaves the ordering exactly
    /// as asked for, which is what an unsorted result wants: an `ORDER BY` there
    /// would turn a scan that stops after 500 rows into one that reads the file.
    public static func rows(
        source: DataSource,
        filters: [Filter] = [],
        sort: [SortKey] = [],
        tiebreak: SortDirection? = nil
    ) -> BoundSQL {
        var params: [String] = [source.readPath]
        var sql = "\(projection(of: source, tiebreak: tiebreak)) "
            + "FROM \(readExpression(of: source, tiebreak: tiebreak)) AS \(sourceAlias)"

        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }

        let terms = tiebreakingOrder(sort, of: source, tiebreak: tiebreak)
        if !terms.isEmpty {
            sql += " ORDER BY " + terms.joined(separator: ", ")
        }

        return BoundSQL(sql: sql, params: params)
    }

    // MARK: - A total order

    /// The ORDER BY terms for `sort`, followed by the source's row-identity
    /// columns when a tiebreaker was asked for.
    ///
    /// `ORDER BY` alone does not name a particular set of rows unless its keys
    /// are unique. Sort a thousand rows by a boolean and you have two tie
    /// groups; which members of a group land in the first page is then settled
    /// by nothing at all, so two executions asked for two adjacent pages are
    /// free to disagree — the same row in both, and some row in neither.
    /// Appending `rowIdentityColumns` makes the order total, so every execution
    /// of every window agrees on where each row sits.
    ///
    /// The direction is the caller's because it has to invert with the rest:
    /// `TableModel.fetchPage` reads a page near the end by turning the whole
    /// ORDER BY around, and a tiebreaker left ascending there would describe a
    /// different sequence than the forward query it has to line up against.
    ///
    /// Empty when `sort` is empty and no tiebreaker was asked for, so the
    /// caller emits no ORDER BY clause at all.
    static func tiebreakingOrder(
        _ sort: [SortKey], of source: DataSource, tiebreak: SortDirection?
    ) -> [String] {
        var terms = sort.map { "\(columnRef($0.column)) \($0.direction.rawValue)" }
        if let tiebreak {
            terms += source.rowIdentityColumns.map { "\(columnRef($0)) \(tiebreak.rawValue)" }
        }
        return terms
    }

    /// `SELECT *`, minus the virtual columns a tiebreaker had to switch on.
    ///
    /// They are generated by the reader, not columns of the data, and the user
    /// did not ask for them — an `id, category, …, file_row_number` grid would
    /// be a visible cost for an invisible fix. `EXCLUDE` drops them from the
    /// projection while leaving them nameable in the ORDER BY, which is exactly
    /// the split this needs.
    static func projection(of source: DataSource, tiebreak: SortDirection?) -> String {
        guard tiebreak != nil else { return "SELECT *" }
        let excluded = source.rowIdentityColumns.map(quote).joined(separator: ", ")
        return "SELECT * EXCLUDE (\(excluded))"
    }

    private static func readExpression(of source: DataSource, tiebreak: SortDirection?) -> String {
        source.readExpression(
            parameterIndex: 1,
            filename: tiebreak != nil && source.rowIdentityColumns.contains(DataSource.fileColumn),
            rowNumber: tiebreak != nil
        )
    }

    /// One file of a dataset, read with the dataset's own options so the
    /// partition columns still arrive and the schema still lines up.
    ///
    /// `hive_partitioning` reads the `key=value` directories off each file's
    /// own path, so a single-file read of a partitioned dataset carries the
    /// same columns, in the same order, with the same types as reading the
    /// whole thing. That is what lets a page be served from one file without
    /// the grid noticing where it came from.
    ///
    /// Deliberately no ORDER BY. This is the read `HivePageIndex` uses, where
    /// the order is the file list and the scan's own order within a file — an
    /// ORDER BY here would reintroduce exactly the ties the index exists to
    /// avoid.
    public static func rows(
        file path: String,
        within source: DataSource,
        filters: [Filter] = [],
        limit: Int,
        offset: Int
    ) -> BoundSQL {
        var params: [String] = [path]
        var sql = "SELECT * FROM \(source.readExpression(parameterIndex: 1)) AS \(sourceAlias)"

        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }

        sql += " LIMIT \(max(limit, 1))"
        if offset > 0 { sql += " OFFSET \(offset)" }
        return BoundSQL(sql: sql, params: params)
    }

    /// Matching rows per file across a dataset, in one pass.
    ///
    /// `HivePageIndex` needs this only when a filter is active: unfiltered, the
    /// parquet footers already say how many rows each file holds. It is one
    /// grouped scan rather than a `count(*)` per file — the same work as the
    /// total the status bar reports, so the answer is bought once.
    public static func rowCountsByFile(source: DataSource, filters: [Filter] = []) -> BoundSQL {
        var params: [String] = [source.readPath]
        let file = quote(DataSource.fileColumn)
        var sql = """
            SELECT \(file) AS file_name, count(*) AS row_count \
            FROM \(source.readExpression(parameterIndex: 1, filename: true)) AS \(sourceAlias)
            """
        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }
        sql += " GROUP BY \(file)"
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
    ///
    /// That includes the tiebreaker, when there is one. It names a column the
    /// user did not ask for and cannot see, which is a fair objection to
    /// showing it — but it is part of what decides which rows are on screen,
    /// and text that quietly leaves it out is text that returns a different
    /// page than the one it claims to describe.
    public static func editableRows(
        source: DataSource,
        filters: [Filter] = [],
        sort: [SortKey] = [],
        tiebreak: SortDirection? = nil
    ) -> String {
        var params: [String] = [source.readPath]
        var lines = [
            projection(of: source, tiebreak: tiebreak),
            "FROM \(readExpression(of: source, tiebreak: tiebreak)) AS \(sourceAlias)",
        ]

        let predicates = filters
            .filter { $0.isEnabled && $0.isComplete }
            .compactMap { predicate(for: $0, params: &params) }
        if !predicates.isEmpty {
            lines.append("WHERE " + predicates.joined(separator: "\n  AND "))
        }

        let terms = tiebreakingOrder(sort, of: source, tiebreak: tiebreak)
        if !terms.isEmpty {
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

    /// Bound a query to the rows the grid is going to show.
    ///
    /// This is the viewer's window, not part of the query: `currentQuery` stays
    /// unbounded so exporting still means every matching row, and the SQL shown
    /// in the editor is the query without it.
    ///
    /// It is what makes sorting a file too large to sort affordable. DuckDB
    /// plans `SELECT * FROM (… ORDER BY x) LIMIT 500` as a **Top-N** — it keeps
    /// 500 rows as it scans rather than materialising and ordering the whole
    /// result before producing a first row. Verified against the vendored
    /// engine's own plan, and asserted in the suite, because the entire value of
    /// the clause is that DuckDB pushes it through the wrapper.
    ///
    /// Wrapped rather than appended so it applies to a query the user typed as
    /// well as one built here, and so it composes with a query that already ends
    /// in its own `LIMIT` (the tighter of the two wins, which is correct).
    ///
    /// `offset` is 0 for the forward-growing window this Top-N pushdown is
    /// written for. A non-zero offset — reading a page anchored somewhere other
    /// than the start, as jumping to the end of the file does — does not get
    /// that pushdown: DuckDB still has to produce and discard everything before
    /// it. That is inherent to asking for an arbitrary middle or tail slice, not
    /// something this clause can fix.
    public static func windowed(_ query: BoundSQL, limit: Int, offset: Int = 0) -> BoundSQL {
        var sql = "SELECT * FROM (\(query.sql)) LIMIT \(max(limit, 1))"
        if offset > 0 { sql += " OFFSET \(offset)" }
        return BoundSQL(sql: sql, params: query.params)
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

    /// A column's distinct values with how many rows carry each, bounded to
    /// `maxDistinct + 1`.
    ///
    /// The same shape of work as `distinctValues` — `DISTINCT` *is* a group-by,
    /// so DuckDB builds the same hash table either way and the counts come off
    /// the groups it already has. That is why the filter list can show them
    /// without the probe costing more than it did without them.
    public static func valueCounts(
        source: DataSource,
        column: ColumnInfo,
        maxDistinct: Int = Probe.defaultMaxDistinct
    ) -> BoundSQL {
        let reference = quote(column.name)
        let sql = """
            SELECT CAST(\(reference) AS VARCHAR) AS value, count(*) AS occurrences \
            FROM \(source.readExpression(parameterIndex: 1)) \
            GROUP BY 1 LIMIT \(maxDistinct + 1)
            """
        return BoundSQL(sql: sql, params: [source.readPath])
    }

    /// A column's distinct values, bounded to `maxDistinct + 1`.
    ///
    /// `SELECT DISTINCT` rather than a `GROUP BY` with counts: this one is only
    /// ever asked how *many* values there are, so there is nothing to count.
    ///
    /// `sampleRows` reads only the head of the source. That is **not** a way to
    /// approximate the answer — a head sample is badly biased, and on a column
    /// whose early rows are all NULL it reports one value where the column has
    /// twenty. It is only ever used to *rule a column out*: more than
    /// `maxDistinct` values in any subset proves more than `maxDistinct` values
    /// overall, so a bounded read can reject a column but can never wrongly
    /// admit one. Pass nil to ask the real question.
    public static func distinctValues(
        source: DataSource,
        column: ColumnInfo,
        sampleRows: Int? = nil,
        maxDistinct: Int = Probe.defaultMaxDistinct
    ) -> BoundSQL {
        let reference = quote(column.name)
        let from: String
        if let sampleRows {
            from = "(SELECT \(reference) FROM \(source.readExpression(parameterIndex: 1)) LIMIT \(sampleRows))"
        } else {
            from = "(SELECT \(reference) FROM \(source.readExpression(parameterIndex: 1)))"
        }
        let sql = """
            SELECT DISTINCT CAST(\(reference) AS VARCHAR) AS value \
            FROM \(from) LIMIT \(maxDistinct + 1)
            """
        return BoundSQL(sql: sql, params: [source.readPath])
    }

    /// A column's distinct values in lexicographic order, capped at `limit`.
    ///
    /// Unlike `distinctValues`, the order is the whole point: this feeds the
    /// completions offered while an equality filter is being typed, where "the
    /// next few values" *is* the answer. It also means a truncated read holds
    /// the lexicographically first values rather than whichever ones the hash
    /// table happened to emit first, so what it holds is exact as far as it goes.
    ///
    /// NULL is excluded. There is nothing to complete it to, and `is null` is
    /// the operator that asks for it.
    ///
    /// `startingAt` narrows to the values at or after some text, so a column
    /// with too many values to hold can still be asked about the stretch being
    /// typed. `ORDER BY … LIMIT` plans as a Top-N, so that stays a bounded scan.
    public static func orderedDistinctValues(
        source: DataSource,
        column: ColumnInfo,
        startingAt lowerBound: String? = nil,
        limit: Int
    ) -> BoundSQL {
        let reference = quote(column.name)
        var params = [source.readPath]
        var sql = """
            SELECT DISTINCT CAST(\(reference) AS VARCHAR) AS value \
            FROM \(source.readExpression(parameterIndex: 1)) \
            WHERE \(reference) IS NOT NULL
            """
        if let lowerBound {
            params.append(lowerBound)
            sql += " AND CAST(\(reference) AS VARCHAR) >= $\(params.count)"
        }
        sql += " ORDER BY value ASC LIMIT \(max(limit, 1))"
        return BoundSQL(sql: sql, params: params)
    }

    // MARK: - Metadata

    /// One row summarising the source, whether it is a file or a thousand of
    /// them.
    ///
    /// Aggregated in DuckDB rather than in the inspector: a dataset's
    /// `parquet_file_metadata` returns a row per file, and summing a truncated
    /// read of those rows would quietly under-report the row count of exactly
    /// the datasets big enough to care about. All of it comes from parquet
    /// footers, so it stays cheap.
    public static func fileMetadata(source: DataSource) -> BoundSQL {
        let sql = """
            SELECT count(*) AS files, sum(num_rows) AS num_rows, \
            sum(num_row_groups) AS num_row_groups, sum(file_size_bytes) AS file_size_bytes, \
            any_value(format_version) AS format_version, any_value(created_by) AS created_by \
            FROM parquet_file_metadata($1)
            """
        return BoundSQL(sql: sql, params: [source.readPath])
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

    /// The paths of the files the source globs, and nothing else.
    ///
    /// `glob` is a directory listing: it opens no file and reads no footer, so
    /// this is the cheapest question that can be asked about a dataset. It is
    /// enough for `HiveSummary`, whose every answer is written in the directory
    /// names the paths are made of.
    public static func fileNames(source: DataSource) -> BoundSQL {
        BoundSQL(sql: "SELECT file FROM glob($1)", params: [source.readPath])
    }

    public static func keyValueMetadata(source: DataSource) -> BoundSQL {
        BoundSQL(
            sql: "SELECT CAST(key AS VARCHAR) AS key, CAST(value AS VARCHAR) AS value FROM parquet_kv_metadata($1)",
            params: [source.readPath]
        )
    }

    // MARK: - Does a folder read as one table?

    /// A read of every parquet file under `directory` that DuckDB refuses
    /// unless their schemas agree — the question behind `DatasetIndex`.
    ///
    /// The glob is the one `DataSource.dataset` would use, so what is asked is
    /// exactly what the "dataset" badge promises: that this folder opens as one
    /// table. What is deliberately left off is `union_by_name`, the option that
    /// makes disagreement survivable — with it on, nothing would ever fail and
    /// the probe would have nothing to report.
    ///
    /// It is shaped to open every file and read none of it. `file_row_number`
    /// is generated by the reader and starts at zero, so `< 0` is false for
    /// every row and DuckDB drops every row group on statistics before touching
    /// a data page; `SELECT *` still names every real column, and it is binding
    /// those against each file in turn that raises "schema mismatch in glob".
    /// The probe therefore costs one footer per file, however many rows they
    /// hold.
    public static func schemaAgreement(under directory: URL) -> BoundSQL {
        BoundSQL(
            sql: """
                SELECT * FROM read_parquet($1, file_row_number = true) \
                WHERE \(quote(DataSource.rowNumberColumn)) < 0
                """,
            params: [DataSource.dataset(directory).readPath]
        )
    }

    /// The same question for a folder whose files already have a column called
    /// `file_row_number`, which the option above cannot be used on at all.
    ///
    /// `random() < 0` is false for every row like the filter it replaces, but it
    /// names no column, so nothing is pruned and every row is examined. That
    /// puts the cost on the rare folder rather than on all of them.
    public static func schemaAgreementWithoutRowNumbers(under directory: URL) -> BoundSQL {
        BoundSQL(
            sql: "SELECT * FROM read_parquet($1) WHERE random() < 0",
            params: [DataSource.dataset(directory).readPath]
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

    /// The codec a parquet export compresses its pages with.
    ///
    /// DuckDB's own default is Snappy, which is fast and weak. ZSTD is the
    /// better default here: DuckParq writes a file once and someone reads it
    /// many times, so a slower write that lands a materially smaller file is
    /// the right trade, and every parquet reader worth naming has read ZSTD for
    /// years. Snappy stays available for a reader that has not.
    public enum ParquetCompression: String, Sendable, CaseIterable, Identifiable {
        case zstd = "ZSTD"
        case snappy = "Snappy"
        case gzip = "GZIP"
        case uncompressed = "None"

        public var id: String { rawValue }

        /// The name DuckDB knows the codec by.
        public var duckDBName: String {
            switch self {
            case .zstd: return "zstd"
            case .snappy: return "snappy"
            case .gzip: return "gzip"
            case .uncompressed: return "uncompressed"
            }
        }
    }

    /// How a parquet export is laid out on disk: which columns become hive
    /// directories, in what order the rows are written, and how they are
    /// compressed once they are.
    ///
    /// None of it means anything for the other formats, so `export` ignores
    /// this for them rather than emitting options DuckDB would reject.
    public struct ParquetLayout: Sendable, Equatable {
        /// Columns to write as `key=value` directory levels, outermost first.
        /// They are *moved* out of the files by DuckDB, not duplicated: a hive
        /// read puts them back by parsing the paths.
        public var partitionBy: [String]

        /// An `ORDER BY` list, exactly as the user typed it.
        ///
        /// This is the one piece of an export that is text rather than
        /// structure, and it is here because the useful orderings are the ones
        /// nothing in the UI can name — `category, ts`, `length(url)`,
        /// `hash(user_id) % 8`. Sorting is what makes a parquet file compress:
        /// runs of equal values are what RLE and dictionary encoding are for,
        /// and a column ordered by something correlated with it lands its
        /// similar values in the same pages.
        ///
        /// Because it is text it must be checked before it runs — see
        /// `exportBody`, which is shaped to be handed to
        /// `DuckDBSession.validateReadOnly` first.
        public var orderBy: String

        /// The page codec. Pairs with `orderBy`: sorting is what creates the
        /// runs of similar values, and the codec is what turns them into a
        /// smaller file.
        public var compression: ParquetCompression

        public static let none = ParquetLayout()

        public init(
            partitionBy: [String] = [],
            orderBy: String = "",
            compression: ParquetCompression = .zstd
        ) {
            self.partitionBy = partitionBy
            self.orderBy = orderBy
            self.compression = compression
        }

        /// The ORDER BY text with surrounding whitespace gone, or nil when the
        /// user left the field alone.
        public var trimmedOrderBy: String? {
            let trimmed = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        public var isPartitioned: Bool { !partitionBy.isEmpty }
    }

    /// What a `COPY` with this layout writes: one file, or a tree of them.
    public static func writesDirectory(format: ExportFormat, layout: ParquetLayout) -> Bool {
        format == .parquet && layout.isPartitioned
    }

    /// The `SELECT` a `COPY` wraps: the grid's query, capped to the rows on
    /// screen, then reordered for the write.
    ///
    /// The order of those two steps is the point. `limit` means "write out what
    /// I am looking at", and which rows those are was settled by the grid's own
    /// ordering — so the cap goes on first and the user's `ORDER BY` rearranges
    /// that set. Ordering first would let a different set of rows survive the
    /// cap than the ones on screen.
    ///
    /// Exposed separately from `export` because `orderBy` is user-written text
    /// interpolated into SQL, and this is the form that can be checked — see
    /// `exportCheck`.
    public static func exportBody(
        query: BoundSQL,
        limit: Int? = nil,
        orderBy: String? = nil
    ) -> BoundSQL {
        var sql = query.sql
        if let limit {
            sql = "SELECT * FROM (\(sql)) LIMIT \(limit)"
        }
        if let orderBy, !orderBy.trimmingCharacters(in: .whitespaces).isEmpty {
            sql = "SELECT * FROM (\(sql)) ORDER BY \(orderBy)"
        }
        return BoundSQL(sql: sql, params: query.params)
    }

    /// The export body as a statement to hand to `DuckDBSession.validateReadOnly`
    /// before the `COPY` runs.
    ///
    /// The ORDER BY field is the only part of an export a person writes as text,
    /// so it is the only part that can be something other than what it looks
    /// like. Checking it as a `SELECT` gets both halves of the answer from
    /// DuckDB itself: the parse rejects a second statement smuggled in past a
    /// semicolon, and the bind names an unknown column while the destination is
    /// still untouched.
    ///
    /// The path is written in rather than bound because the bind is the point.
    /// A statement whose source is still `read_parquet($1)` has no schema yet —
    /// nothing to resolve `ORDER BY total` against — so it would pass here and
    /// fail halfway through the write. This statement is only ever prepared,
    /// never executed; the `COPY` that runs still binds its parameters.
    public static func exportCheck(
        query: BoundSQL,
        limit: Int? = nil,
        orderBy: String? = nil
    ) -> String {
        inlined(exportBody(query: query, limit: limit, orderBy: orderBy))
    }

    /// `COPY (<query>) TO <destination>`. The destination is a bound parameter,
    /// and `limit` caps the export to what the user is looking at when they ask
    /// for the current view rather than the whole filtered set.
    ///
    /// With `layout.partitionBy` set, the destination names a *directory*:
    /// DuckDB writes `key=value/...` levels under it, one file per combination.
    /// Deliberately no `OVERWRITE_OR_IGNORE` — writing into a directory that
    /// already holds an export would leave last time's files sitting alongside
    /// this time's, and a dataset half of which is stale reads as one table
    /// without complaint. DuckDB refuses instead, and says so.
    public static func export(
        query: BoundSQL,
        to destination: URL,
        format: ExportFormat,
        limit: Int? = nil,
        layout: ParquetLayout = .none
    ) -> BoundSQL {
        let body = exportBody(
            query: query,
            limit: limit,
            orderBy: format == .parquet ? layout.trimmedOrderBy : nil
        )
        var params = body.params
        params.append(destination.path)

        var options = format.copyOptions
        if format == .parquet {
            options += ", COMPRESSION \(layout.compression.duckDBName)"
            if layout.isPartitioned {
                let keys = layout.partitionBy.map(quote).joined(separator: ", ")
                options += ", PARTITION_BY (\(keys))"
            }
        }
        return BoundSQL(sql: "COPY (\(body.sql)) TO $\(params.count) (\(options))", params: params)
    }
}
