import DuckParqCore
import Foundation

// A Command Line Tools-only toolchain has neither XCTest nor swift-testing, so
// the suite is a plain executable. Run it with `make test`.

private nonisolated(unsafe) var failures = 0
private nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ description: String, file: StaticString = #filePath, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write("FAIL: \(description)  (\(file):\(line))\n".data(using: .utf8)!)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        let message = """
            FAIL: \(description)
              expected: \(expected)
              actual:   \(actual)  (\(file):\(line))

            """
        FileHandle.standardError.write(message.data(using: .utf8)!)
    }
}

func section(_ name: String) {
    print("\n— \(name)")
}

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // DuckParqSelfTest
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // package root
let fixtures = packageRoot.appendingPathComponent(".fixtures")
let smallParquet = fixtures.appendingPathComponent("small.parquet")
let typesParquet = fixtures.appendingPathComponent("types.parquet")
let hiveDirectory = fixtures.appendingPathComponent("hive")
let corruptParquet = fixtures.appendingPathComponent("corrupt.parquet")

guard FileManager.default.fileExists(atPath: smallParquet.path) else {
    FileHandle.standardError.write("fixtures missing — run `make fixtures`\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - Identifier quoting

section("SQLBuilder quoting")

expectEqual(SQLBuilder.quote("plain"), "\"plain\"", "simple identifier is quoted")
expectEqual(SQLBuilder.quote("weird \"name"), "\"weird \"\"name\"", "embedded quote is doubled")
expectEqual(SQLBuilder.columnRef("a"), "t.\"a\"", "column references are alias-qualified")

// MARK: - Filter compilation

section("Filter compilation")

let scoreColumn = ColumnInfo(name: "score", typeName: "BIGINT")
let labelColumn = ColumnInfo(name: "label", typeName: "VARCHAR")
let listColumn = ColumnInfo(name: "int_list", typeName: "BIGINT[]")

do {
    let filter = Filter(column: scoreColumn, mode: .comparison(.greaterThan, ["100"]))
    let built = SQLBuilder.rows(source: .file(smallParquet), filters: [filter])
    expect(built.sql.contains("t.\"score\" > CAST($2 AS BIGINT)"),
           "comparison casts the parameter to the column type, not the reverse")
    expectEqual(built.params, [smallParquet.path, "100"], "path and operand are both bound")
}

do {
    let filter = Filter(column: labelColumn, mode: .comparison(.contains, ["50%_off"]))
    let built = SQLBuilder.rows(source: .file(smallParquet), filters: [filter])
    expect(built.sql.contains("contains(CAST(t.\"label\" AS VARCHAR), $2)"),
           "contains uses the function form so % and _ stay literal")
    expect(!built.sql.contains("LIKE"), "contains does not degrade into LIKE")
    expectEqual(built.params.last, "50%_off", "the operand is bound verbatim")
}

do {
    let filter = Filter(column: scoreColumn, mode: .anyOf(["1", "2"], includeNull: true))
    let built = SQLBuilder.rows(source: .file(smallParquet), filters: [filter])
    expect(built.sql.contains("IN (CAST($2 AS BIGINT), CAST($3 AS BIGINT))"), "set membership binds each value")
    expect(built.sql.contains("IS NULL"), "including NULL adds an explicit IS NULL arm")
}

do {
    let filter = Filter(column: scoreColumn, mode: .comparison(.between, ["10", "20"]))
    let built = SQLBuilder.rows(source: .file(smallParquet), filters: [filter])
    expect(built.sql.contains("BETWEEN CAST($2 AS BIGINT) AND CAST($3 AS BIGINT)"), "between binds both bounds")
}

do {
    let incomplete = Filter(column: scoreColumn, mode: .comparison(.equal, [""]))
    expect(!incomplete.isComplete, "a filter with an empty operand is incomplete")
    let built = SQLBuilder.rows(source: .file(smallParquet), filters: [incomplete])
    expect(!built.sql.contains("WHERE"), "incomplete filters are not sent to DuckDB")

    let disabled = Filter(column: scoreColumn, mode: .comparison(.equal, ["5"]), isEnabled: false)
    let built2 = SQLBuilder.rows(source: .file(smallParquet), filters: [disabled])
    expect(!built2.sql.contains("WHERE"), "disabled filters are not sent to DuckDB")
}

expectEqual(FilterOperator.available(for: .nested), [.contains, .isNull, .isNotNull],
            "nested columns only get presence and substring filters")
expect(!FilterOperator.available(for: .text).contains(.lessThan),
       "text columns are not offered ordered comparisons")
expect(FilterOperator.available(for: .integer).contains(.between), "numeric columns get BETWEEN")

// MARK: - Type classification

section("Column kinds")

expectEqual(ColumnInfo(name: "c", typeName: "BIGINT[]").kind, .nested, "arrays are nested, not integer")
expectEqual(ColumnInfo(name: "c", typeName: "STRUCT(a BIGINT)").kind, .nested, "structs are nested")
expectEqual(ColumnInfo(name: "c", typeName: "DECIMAL(18,4)").kind, .decimal, "decimals are recognised")
expectEqual(ColumnInfo(name: "c", typeName: "TIMESTAMP WITH TIME ZONE").kind, .timestamp, "timestamptz is a timestamp")
expectEqual(ColumnInfo(name: "c", typeName: "HUGEINT").kind, .integer, "hugeint is an integer")
expectEqual(ColumnInfo(name: "c", typeName: "BLOB").kind, .binary, "blobs are binary")
expectEqual(ColumnInfo(name: "c", typeName: "VARCHAR").kind, .text, "varchar is text")
expect(ColumnInfo(name: "c", typeName: "DOUBLE").kind.prefersTrailingAlignment, "numbers align trailing")
expect(!ColumnInfo(name: "c", typeName: "VARCHAR").kind.prefersTrailingAlignment, "text aligns leading")

// MARK: - Sort clause

section("Sort")

do {
    let built = SQLBuilder.rows(
        source: .file(smallParquet),
        sort: [SortKey(column: "score", direction: .descending), SortKey(column: "id", direction: .ascending)]
    )
    expect(built.sql.hasSuffix("ORDER BY t.\"score\" DESC, t.\"id\" ASC"),
           "multiple sort keys are emitted in order, alias-qualified")

    let unsorted = SQLBuilder.rows(source: .file(smallParquet), sort: [])
    expect(!unsorted.sql.contains("ORDER BY"), "no sort means no ORDER BY at all")
}

// MARK: - File tree

section("File tree")

do {
    let listing = FileTree.listing(of: fixtures)
    expectEqual(listing.outcome, .ok, "a readable directory lists successfully")
    expect(listing.nodes.contains { $0.name == "small.parquet" }, "parquet files are listed")
    expect(listing.nodes.contains { $0.name == "hive" && $0.isDataset },
           "a hive directory is flagged as a dataset")
    expect(!listing.nodes.contains { $0.name.hasSuffix(".ips") }, "non-parquet files are hidden")

    // Directories sort before files, so the tree reads top-down.
    let firstFileIndex = listing.nodes.firstIndex { !$0.isDirectory } ?? listing.nodes.count
    expect(listing.nodes.prefix(firstFileIndex).allSatisfy(\.isDirectory),
           "directories are listed before files")

    // An unreadable directory must be distinguishable from an empty one —
    // otherwise the sidebar silently shows "no parquet files" when the real
    // problem is that macOS refused access.
    let missing = FileTree.listing(of: fixtures.appendingPathComponent("does-not-exist"))
    expect(missing.outcome != .ok, "an unreadable directory reports why, not just an empty list")
    expect(missing.nodes.isEmpty, "a failed listing yields no nodes")

    expect(FileTree.looksLikeDataset(fixtures), "a folder holding parquet files reads as a dataset")
    expect(FileTree.looksLikeDataset(hiveDirectory), "a hive-partitioned folder reads as a dataset")

    let datasetSource = DataSource.dataset(hiveDirectory)
    expect(datasetSource.readPath.hasSuffix("/**/*.parquet"), "datasets read recursively")
}

// MARK: - Column layout

section("Column layout")

do {
    let cols = [
        ColumnInfo(name: "symbol", typeName: "VARCHAR"),
        ColumnInfo(name: "Date", typeName: "DATE"),
        ColumnInfo(name: "Open", typeName: "DOUBLE"),
    ]
    let rows = [
        TableModel.GridRow(id: 0, cells: ["A", "2000-11-14", "28.880542755126953"]),
        TableModel.GridRow(id: 1, cells: ["AAPL", "2000-11-15", "30.57939190888672"]),
    ]

    let widths = ColumnLayout.widths(for: cols, rows: rows)
    expectEqual(widths.count, cols.count, "there is exactly one width per column")

    // The header and every row are handed this same array, so the only way they
    // can disagree is if the array itself is inconsistent — hence checking that
    // repeated calls with the same inputs are identical.
    expectEqual(ColumnLayout.widths(for: cols, rows: rows), widths,
                "width computation is deterministic for the same inputs")

    // A column of long values must be wider than one of short values, or the
    // content overflows into its neighbour's space.
    expect(widths[2] > widths[0], "a wide numeric column is wider than a short text column")

    expect(widths.allSatisfy { $0 >= ColumnLayout.minWidth && $0 <= ColumnLayout.maxWidth },
           "every width is clamped to the allowed range")

    // A long header name still gets room even when its values are tiny.
    let longHeader = ColumnLayout.widths(
        for: [ColumnInfo(name: "a_very_long_column_name_here", typeName: "VARCHAR")],
        rows: [TableModel.GridRow(id: 0, cells: ["x"])])
    expect(longHeader[0] > ColumnLayout.minWidth, "a long header name widens its column")

    // Duplicate names are positional, not collapsed — a name-keyed layout would
    // return one width for two columns and shift everything after them.
    let dupes = [
        ColumnInfo(name: "id", typeName: "BIGINT"),
        ColumnInfo(name: "id", typeName: "VARCHAR"),
        ColumnInfo(name: "", typeName: "VARCHAR"),
    ]
    let dupeWidths = ColumnLayout.widths(
        for: dupes,
        rows: [TableModel.GridRow(id: 0, cells: ["1", "a-much-longer-value-here", "z"])])
    expectEqual(dupeWidths.count, 3, "duplicate and empty column names still get one width each")
    expect(dupeWidths[1] > dupeWidths[0], "the second duplicate is sized from its own column's data")

    // NULL renders as literal text, so it needs to be measured as such.
    let nullWidths = ColumnLayout.widths(
        for: [ColumnInfo(name: "c", typeName: "VARCHAR")],
        rows: [TableModel.GridRow(id: 0, cells: [nil])])
    expect(nullWidths[0] >= ColumnLayout.minWidth, "a column of NULLs is still measurable")

    // A dragged width wins over measurement, and is still clamped.
    let overridden = ColumnLayout.widths(for: cols, rows: rows, overrides: ["Open": 300])
    expectEqual(overridden[2], 300, "a manual width override is respected")
    expectEqual(overridden[0], widths[0], "overriding one column leaves the others alone")
    let absurd = ColumnLayout.widths(for: cols, rows: rows, overrides: ["Open": 5000])
    expectEqual(absurd[2], ColumnLayout.maxWidth, "an override is clamped to the maximum")
}

// MARK: - Engine round-trip

section("Engine round-trip")

let engine = try DuckDBEngine()
print("  duckdb \(engine.duckdbVersion)")
let session = try DuckDBSession(engine: engine, label: "selftest")
let probe = Probe(session: session)

let columns = try await probe.columns(of: .file(smallParquet))
expectEqual(columns.map(\.name), ["id", "category", "score", "flagged", "day", "label"],
            "DESCRIBE returns the fixture's columns in order")
expectEqual(columns.first?.typeName, "BIGINT", "id is a BIGINT")

let count = try await probe.rowCount(of: .file(smallParquet))
expectEqual(count, 1000, "row count matches the fixture")

// Sorting must be DuckDB's, and must survive the bridge's VARCHAR wrap: a
// lexicographic sort would give 0, 1, 10, 100 here rather than 0, 1, 2, 3.
do {
    let built = SQLBuilder.rows(source: .file(smallParquet), sort: [SortKey(column: "score", direction: .ascending)])
    let cursor = try await session.openCursor(built.sql, params: built.params)
    let page = try await cursor.fetch(maxRows: 8)
    await cursor.close()
    let scoreIndex = cursor.columnNames.firstIndex(of: "score")!
    let scores = (0..<(page?.rowCount ?? 0)).map { page!.cells[$0 * cursor.columnNames.count + scoreIndex] ?? "" }
    expectEqual(scores, ["0", "1", "2", "3", "4", "5", "6", "7"],
                "ORDER BY sorts numerically through the VARCHAR wrap")
}

// Paging must be a continuation of one stream, not repeated queries.
do {
    let built = SQLBuilder.rows(source: .file(smallParquet), sort: [SortKey(column: "id", direction: .ascending)])
    let cursor = try await session.openCursor(built.sql, params: built.params)
    let idIndex = cursor.columnNames.firstIndex(of: "id")!
    var ids: [Int] = []
    while let page = try await cursor.fetch(maxRows: 300) {
        for row in 0..<page.rowCount {
            ids.append(Int(page.cells[row * page.columnCount + idIndex] ?? "") ?? -1)
        }
    }
    await cursor.close()
    expectEqual(ids.count, 1000, "paging reaches the end of the stream exactly once")
    expectEqual(ids, Array(0..<1000), "pages continue the stream rather than restarting it")
}

// Every DuckDB type must survive the bridge as displayable text.
do {
    let built = SQLBuilder.rows(source: .file(typesParquet), sort: [SortKey(column: "id", direction: .ascending)])
    let cursor = try await session.openCursor(built.sql, params: built.params)
    let page = try await cursor.fetch(maxRows: 3)!
    await cursor.close()
    let names = cursor.columnNames

    func cell(_ row: Int, _ column: String) -> String? {
        guard let index = names.firstIndex(of: column) else { return nil }
        return page.cells[row * page.columnCount + index]
    }

    expectEqual(cell(0, "amount"), String?.none, "SQL NULL arrives as nil, not an empty string")
    expectEqual(cell(1, "amount"), "1.5000", "DECIMAL keeps its scale")
    expectEqual(cell(0, "int_list"), "[0, 1, 2]", "LIST renders")
    expectEqual(cell(0, "meta"), "{'name': n0, 'size': 0}", "STRUCT renders")
    expectEqual(cell(0, "payload"), "blob-0", "BLOB renders")
    expect(cell(0, "ts")?.hasPrefix("2024-06-01") == true, "TIMESTAMPTZ renders")
    expectEqual(cell(0, "even"), "true", "BOOLEAN renders")
}

// Hive-partitioned directories read as a single dataset, with partition keys
// surfacing as columns.
do {
    let dataset = DataSource.dataset(hiveDirectory)
    let datasetColumns = try await probe.columns(of: dataset)
    expect(datasetColumns.contains { $0.name == "year" }, "hive partition key appears as a column")
    expect(datasetColumns.contains { $0.name == "region" }, "second partition key appears as a column")
    let datasetRows = try await probe.rowCount(of: dataset)
    expectEqual(datasetRows, 3000, "the whole partitioned dataset is read")
}

// Filters must reach DuckDB and actually restrict the result.
do {
    let filter = Filter(column: ColumnInfo(name: "category", typeName: "VARCHAR"),
                        mode: .anyOf(["alpha"], includeNull: false))
    let filtered = try await probe.rowCount(of: .file(smallParquet), filters: [filter])
    expectEqual(filtered, 250, "a dropdown filter restricts the row count")
}

// Cardinality classification drives which widget the UI offers.
do {
    let affordance = try await probe.filterAffordance(
        for: ColumnInfo(name: "category", typeName: "VARCHAR"), in: .file(smallParquet))
    if case .dropdown(let values, let hasNull, _) = affordance {
        expectEqual(values, ["alpha", "beta", "delta", "gamma"], "low-cardinality column offers its values")
        expect(!hasNull, "no NULLs in the category fixture")
    } else {
        expect(false, "a 4-value column should offer a dropdown")
    }

    let wide = try await probe.filterAffordance(
        for: ColumnInfo(name: "label", typeName: "VARCHAR"), in: .file(smallParquet))
    expectEqual(wide, .comparison, "a 1000-value column falls back to comparison operators")
}

// Errors must arrive as messages rather than crashes.
do {
    var raised: String?
    do {
        _ = try await probe.rowCount(of: .file(corruptParquet))
    } catch let error as DuckDBError {
        raised = error.errorDescription
    }
    expect(raised != nil, "a corrupt parquet file surfaces an error")
    expect(raised?.isEmpty == false, "the error carries DuckDB's message")
}

// Interrupting a session cancels its in-flight work rather than orphaning it.
do {
    let cancelSession = try DuckDBSession(engine: engine, label: "cancel")
    let started = Date()
    let work = Task { () -> Bool in
        do {
            // A deliberately expensive query with no file dependency.
            _ = try await cancelSession.queryAll(
                "SELECT count(*) FROM range(20000000000) t(i) WHERE i % 7 = 0", limit: 1)
            return false
        } catch {
            return (error as? DuckDBError)?.isCancellation ?? false
        }
    }
    try? await Task.sleep(for: .milliseconds(300))
    cancelSession.interrupt()
    let cancelled = await work.value
    let elapsed = Date().timeIntervalSince(started)
    expect(cancelled, "interrupt surfaces as a cancellation, not a generic failure")
    expect(elapsed < 10, "interrupt actually stops the query (took \(String(format: "%.1f", elapsed))s)")

    // The grid interrupts and immediately re-queries on the same session every
    // time the user changes sort, so a stale interrupt flag must not poison the
    // next query.
    let after = try await cancelSession.queryAll("SELECT 42 AS answer", limit: 1)
    expectEqual(after[0, 0], "42", "a session is reusable straight after an interrupt")

    // And repeatedly, the way rapid re-sorting would.
    for round in 1...3 {
        let slow = Task { () -> Bool in
            do {
                _ = try await cancelSession.queryAll(
                    "SELECT count(*) FROM range(20000000000) t(i) WHERE i % 7 = 0", limit: 1)
                return false
            } catch {
                return (error as? DuckDBError)?.isCancellation ?? false
            }
        }
        try? await Task.sleep(for: .milliseconds(120))
        cancelSession.interrupt()
        _ = await slow.value
        let recovered = try await cancelSession.queryAll("SELECT \(round) AS n", limit: 1)
        expectEqual(recovered[0, 0], "\(round)", "session recovers after interrupt round \(round)")
    }
}

// Concurrent queries on one session must not interfere. DuckDB allows a single
// active streaming result per connection, so each cursor needs its own — when
// they shared one, a second query invalidated the first's pending result and
// the loser failed with "unsuccessful or closed pending query result".
do {
    let shared = try DuckDBSession(engine: engine, label: "concurrent")
    let sharedProbe = Probe(session: shared)

    async let columnsResult = sharedProbe.columns(of: .file(smallParquet))
    async let countResult = sharedProbe.rowCount(of: .file(smallParquet))
    async let typesResult = sharedProbe.columns(of: .file(typesParquet))
    let (a, b, c) = try await (columnsResult, countResult, typesResult)

    expectEqual(a.count, 6, "concurrent DESCRIBE on a shared session succeeds")
    expectEqual(b, 1000, "concurrent count on a shared session succeeds")
    expectEqual(c.count, 9, "a third concurrent query on the same session succeeds")

    // Two cursors held open simultaneously on one session must both stay valid.
    let first = try await shared.openCursor("SELECT i FROM range(5000) t(i) ORDER BY i")
    let second = try await shared.openCursor("SELECT i FROM range(5000) t(i) ORDER BY i DESC")
    let firstPage = try await first.fetch(maxRows: 3)
    let secondPage = try await second.fetch(maxRows: 3)
    await first.close()
    await second.close()
    expectEqual(firstPage?.cells.first ?? "", "0", "the first of two open cursors still reads")
    expectEqual(secondPage?.cells.first ?? "", "4999", "the second open cursor reads independently")
}

// MARK: - Read-only policy

section("Read-only policy")

// The C bridge re-encodes duckdb_statement_type into its own enum, and Swift
// mirrors that by raw value. Drift between the two would silently reclassify
// writes as reads, so pin the mapping at both ends.
expectEqual(StatementKind(rawValue: 0), .other, "kind 0 is the fail-closed case")
expectEqual(StatementKind(rawValue: 1), .select, "kind 1 is SELECT")
expectEqual(StatementKind(rawValue: 2), .explain, "kind 2 is EXPLAIN")
expectEqual(StatementKind(rawValue: 9), .copy, "kind 9 is COPY")
expectEqual(StatementKind(rawValue: 99), nil, "unknown raw values do not decode")
expectEqual(SQLPolicy.readOnlyKinds, [.select, .explain], "only reads are allowed")
expect(!SQLPolicy.isReadOnly(.other), "an unrecognised statement is rejected")

do {
    let guardSession = try DuckDBSession(engine: engine, label: "policy")
    // The `t` view has to exist for statements that reference it to bind. This
    // is the exact statement the app runs on selection, so a regression in it
    // fails here rather than silently leaving `FROM t` broken in the editor.
    try await guardSession.execute(SQLBuilder.createSourceView(.file(smallParquet)))
    let viewRows = try await guardSession.queryAll("SELECT count(*) FROM t")
    expectEqual(viewRows[0, 0], "1000", "the selection is queryable as `t`")

    // …and from a different connection, which is where the TEMP version failed.
    let otherSession = try DuckDBSession(engine: engine, label: "policy-other")
    let crossRows = try await otherSession.queryAll("SELECT count(*) FROM t")
    expectEqual(crossRows[0, 0], "1000", "`t` is visible to the session that runs queries")

    // DuckDB parses all of these as SELECT, which is why the allow-list can be
    // this small and still cover what a viewer needs.
    let reads = [
        "SELECT * FROM t",
        "select ID from t where id < 10",
        "WITH x AS (SELECT * FROM t) SELECT count(*) FROM x",
        "FROM t LIMIT 5",
        "DESCRIBE SELECT * FROM t",
        "SUMMARIZE t",
        "SHOW TABLES",
        "EXPLAIN SELECT * FROM t",
        "SELECT * FROM t;",
        "-- a comment\nSELECT 1",
    ]
    for sql in reads {
        var rejection: String?
        do { try await guardSession.validateReadOnly(sql) } catch { rejection = error.localizedDescription }
        expect(rejection == nil, "read is allowed: \(sql) — \(rejection ?? "")")
    }

    // Each of these would change data, the catalog, the filesystem or the
    // engine's configuration.
    let writes: [(String, String)] = [
        ("CREATE TABLE evil AS SELECT 1", "CREATE"),
        ("CREATE TEMP VIEW evil AS SELECT 1", "CREATE"),
        ("DROP VIEW t", "DROP"),
        ("COPY (SELECT * FROM t) TO '/tmp/duckparq-should-not-exist.csv'", "COPY"),
        ("EXPORT DATABASE '/tmp/duckparq-should-not-exist'", "EXPORT"),
        ("ATTACH '/tmp/duckparq-should-not-exist.db' AS e", "ATTACH"),
        ("INSTALL httpfs", "INSTALL/LOAD"),
        ("LOAD httpfs", "INSTALL/LOAD"),
        ("SET threads = 1", "SET"),
        ("CHECKPOINT", "CALL"),
        ("BEGIN TRANSACTION", "transaction control"),
        ("PREPARE p AS SELECT 1", "PREPARE"),
        ("VACUUM", "VACUUM"),
    ]
    for (sql, expected) in writes {
        do {
            try await guardSession.validateReadOnly(sql)
            expect(false, "write is rejected: \(sql)")
        } catch let error as SQLPolicyError {
            expectEqual(error, .notReadOnly(StatementKind.allCases.first { $0.displayName == expected } ?? .other),
                        "rejects \(sql) as \(expected)")
        } catch {
            expect(false, "write is rejected as a policy error: \(sql) — \(error)")
        }
    }

    // The case the whole check exists for: a write hidden behind a read. A
    // text-matching guard that stopped at the first statement would pass this.
    do {
        try await guardSession.validateReadOnly("SELECT * FROM t; DROP VIEW t")
        expect(false, "a write chained after a read is rejected")
    } catch let error as SQLPolicyError {
        expectEqual(error, .multipleStatements(2), "chained statements are rejected as multiple")
    } catch {
        expect(false, "chained statements raise a policy error, got \(error)")
    }

    // ... and it is genuinely still there afterwards.
    let survived = try await guardSession.queryAll("SELECT count(*) FROM t")
    expectEqual(survived[0, 0], "1000", "the view a rejected DROP targeted is intact")

    do {
        try await guardSession.validateReadOnly("SELECT 1; SELECT 2")
        expect(false, "even two reads are one too many")
    } catch let error as SQLPolicyError {
        expectEqual(error, .multipleStatements(2), "two reads are still multiple statements")
    } catch {
        expect(false, "two reads raise a policy error, got \(error)")
    }

    // Nonsense is DuckDB's own parse error, passed through unchanged.
    do {
        try await guardSession.validateReadOnly("SELECT FROM WHERE")
        expect(false, "unparseable text is rejected")
    } catch {
        expect(error is DuckDBError, "a parse failure surfaces DuckDB's message")
    }
}

// MARK: - SQL shown to the user

section("Editable SQL")

expectEqual(SQLBuilder.literal("plain"), "'plain'", "literals are single-quoted")
expectEqual(SQLBuilder.literal("it's"), "'it''s'", "embedded quotes are doubled")

expectEqual(
    SQLBuilder.inlined(BoundSQL(sql: "SELECT $1, $2", params: ["a", "b"])),
    "SELECT 'a', 'b'",
    "placeholders become literals"
)
expectEqual(
    SQLBuilder.inlined(BoundSQL(sql: "SELECT $10, $1", params: (1...10).map(String.init))),
    "SELECT '10', '1'",
    "multi-digit placeholders are not mistaken for $1"
)
expectEqual(
    SQLBuilder.inlined(BoundSQL(sql: "SELECT t.\"total$1\" FROM x WHERE a = $1", params: ["v"])),
    "SELECT t.\"total$1\" FROM x WHERE a = 'v'",
    "a column named with a $ is left alone"
)
expectEqual(
    SQLBuilder.inlined(BoundSQL(sql: "SELECT '$1' , $1", params: ["v"])),
    "SELECT '$1' , 'v'",
    "placeholders inside string literals are left alone"
)
expectEqual(
    SQLBuilder.inlined(BoundSQL(sql: "SELECT $3", params: ["a"])),
    "SELECT $3",
    "an out-of-range placeholder is left as written"
)

do {
    let filters = [
        Filter(column: scoreColumn, mode: .comparison(.greaterThan, ["10"])),
        Filter(column: labelColumn, mode: .comparison(.equal, ["it's"])),
    ]
    let sort = [SortKey(column: "id", direction: .descending)]
    let text = SQLBuilder.editableRows(source: .file(smallParquet), filters: filters, sort: sort)

    expect(text.contains(SQLBuilder.literal(smallParquet.path)), "the path is written out in full")
    expect(!text.contains("$1"), "no placeholders are left for the user to puzzle over")
    expect(text.contains("'it''s'"), "operands are escaped, not concatenated")
    expect(text.contains("\nWHERE "), "clauses are on their own lines")
    expect(text.contains("\nORDER BY "), "the sort is visible in the SQL")

    // The point of the feature: what is shown is what is running. Run both the
    // bound query the grid uses and the text handed to the editor, and require
    // identical results.
    let bound = SQLBuilder.rows(source: .file(smallParquet), filters: filters, sort: sort)
    let fromGrid = try await session.queryAll(bound.sql, params: bound.params, limit: 200)
    let fromEditor = try await session.queryAll(text, limit: 200)
    expectEqual(fromEditor.columns, fromGrid.columns, "editable SQL selects the same columns")
    expectEqual(fromEditor.rowCount, fromGrid.rowCount, "editable SQL returns the same rows")
    expectEqual(fromEditor.cells, fromGrid.cells, "editable SQL returns the same values")

    // And it is itself something the policy will let the user run.
    var rejection: String?
    do { try await session.validateReadOnly(text) } catch { rejection = error.localizedDescription }
    expect(rejection == nil, "the SQL shown to the user passes the read-only check — \(rejection ?? "")")

    let plain = SQLBuilder.editableRows(source: .dataset(hiveDirectory))
    expect(plain.contains("hive_partitioning"), "a dataset shows the options it is read with")
    expectEqual(plain.contains("WHERE"), false, "no filters means no WHERE clause")

    // One implementation of the read_parquet(…) text, used by the editor's
    // Insert Path, the sidebar's copy action, and the `t` view.
    expectEqual(
        SQLBuilder.readExpression(for: .file(URL(fileURLWithPath: "/tmp/it's here.parquet"))),
        "read_parquet('/tmp/it''s here.parquet')",
        "an apostrophe in a path is escaped, not left to close the string"
    )
    expect(
        SQLBuilder.createSourceView(.file(URL(fileURLWithPath: "/tmp/it's here.parquet")))
            .contains("'/tmp/it''s here.parquet'"),
        "the same escaping applies to the view statement"
    )
}

// MARK: - Syntax highlighting

section("SQL syntax")

do {
    // The keyword set comes from the engine, not a hardcoded list.
    let loaded = await SQLKeywords.shared.load(using: session)
    expect(loaded, "keywords load from duckdb_keywords()")
    let keywords = SQLKeywords.shared.all
    expect(keywords.count > 400, "the engine knows several hundred keywords, got \(keywords.count)")
    expect(keywords.contains("SELECT"), "SELECT is a keyword")
    expect(keywords.contains("TRUE") && keywords.contains("NULL"),
           "TRUE and NULL are keywords, which is why the CLI bolds them")
    // Functions are not keywords — the CLI leaves them uncoloured, and so must we.
    expect(!keywords.contains("COUNT"), "count() is a function, not a keyword")
    expect(!keywords.contains("READ_PARQUET"), "read_parquet() is a function, not a keyword")
    expect(SQLKeywords.bootstrap.isSubset(of: keywords),
           "every bootstrap keyword is a real DuckDB keyword")

    func kinds(_ sql: String) -> [SQLTokenKind] {
        SQLSyntax.tokenize(sql, keywords: keywords).map(\.kind)
    }
    func text(_ sql: String, _ token: SQLToken) -> String {
        (sql as NSString).substring(with: NSRange(location: token.location, length: token.length))
    }

    expectEqual(kinds("SELECT 1"), [.keyword, .numericConstant], "keyword then number")
    expectEqual(kinds("select x from t"), [.keyword, .identifier, .keyword, .identifier],
                "keywords are recognised in lower case")
    expectEqual(kinds("SELECT 'abc'"), [.keyword, .stringConstant], "single quotes are a string")
    expectEqual(kinds("SELECT \"select\""), [.keyword, .quotedIdentifier],
                "a quoted identifier is never a keyword, however it is spelled")
    expectEqual(kinds("x::VARCHAR"), [.identifier, .keyword, .keyword],
                "`::` reads as a keyword, matching the CLI")
    expectEqual(kinds("a > 1"), [.identifier, .operator, .numericConstant],
                "ordinary operators stay uncoloured")
    expectEqual(kinds("SELECT 1.5e3, 0x1F, .5"),
                [.keyword, .numericConstant, .operator, .numericConstant, .operator, .numericConstant],
                "exponents, hex and leading-dot numbers all scan as one number each")
    expectEqual(kinds("count(*)"), [.identifier, .operator, .operator, .operator],
                "a function name is an identifier, like the CLI leaves it")
    expectEqual(kinds("größe"), [.identifier], "a non-ASCII identifier is one identifier")

    // Comments.
    expectEqual(kinds("SELECT 1 -- note\nSELECT 2"),
                [.keyword, .numericConstant, .comment, .keyword, .numericConstant],
                "a line comment ends at the newline")
    expectEqual(kinds("/* a /* nested */ b */ SELECT"), [.comment, .keyword],
                "block comments nest, as DuckDB allows")
    expectEqual(kinds("/* unterminated"), [.comment], "an unclosed block comment is still a comment")

    // Escapes and the unterminated cases the CLI paints red.
    do {
        let sql = "SELECT 'it''s here' FROM t"
        let tokens = SQLSyntax.tokenize(sql, keywords: keywords)
        expectEqual(tokens.map(\.kind), [.keyword, .stringConstant, .keyword, .identifier],
                    "a doubled quote does not end the string")
        expectEqual(text(sql, tokens[1]), "'it''s here'", "the whole literal is one token")
    }
    expectEqual(kinds("SELECT 'unterminated"), [.keyword, .error],
                "an unclosed string is an error token")
    expectEqual(kinds("SELECT \"unterminated"), [.keyword, .error],
                "an unclosed quoted identifier is an error token")

    // Structural invariants. Ranges are handed straight to NSAttributedString,
    // so an overlap or an out-of-bounds range is a crash, not a wrong colour.
    let samples = [
        "",
        "   \n\t ",
        "'",
        "--",
        "SELECT * FROM read_parquet('/tmp/it''s.parquet') AS t WHERE t.\"a b\" > 1.5 -- x",
        SQLBuilder.editableRows(
            source: .file(smallParquet),
            filters: [Filter(column: labelColumn, mode: .comparison(.contains, ["o'x"]))],
            sort: [SortKey(column: "id", direction: .descending)]
        ),
    ]
    for sample in samples {
        let length = (sample as NSString).length
        let tokens = SQLSyntax.tokenize(sample, keywords: keywords)
        var previousEnd = 0
        var ordered = true
        var inBounds = true
        for token in tokens {
            if token.location < previousEnd { ordered = false }
            if token.length <= 0 || token.end > length { inBounds = false }
            previousEnd = token.end
        }
        expect(ordered, "tokens are ordered and non-overlapping: \(sample.prefix(40))")
        expect(inBounds, "tokens stay inside the text: \(sample.prefix(40))")

        // Everything not covered by a token must be whitespace — no character
        // may be silently dropped by the scanner.
        let units = Array(sample.utf16)
        var covered = [Bool](repeating: false, count: units.count)
        for token in tokens {
            for offset in token.location..<token.end { covered[offset] = true }
        }
        let gapsAreBlank = zip(units, covered).allSatisfy { unit, isCovered in
            isCovered || unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
        }
        expect(gapsAreBlank, "only whitespace falls between tokens: \(sample.prefix(40))")
    }

    // MARK: Against the real CLI
    //
    // These reference strings are not written by hand. They were captured from
    // `duckdb` v1.5.5 — the version vendored here — driven under a pty:
    //
    //     duckdb -init /dev/null -dark-mode     (and -light-mode)
    //
    // Each is one rendered input line, escape sequences and all. The test
    // decodes them into a colour per character and requires DuckParq to assign
    // the same colour to every non-blank character. Whitespace is exempt
    // because linenoise paints trailing spaces with whatever colour preceded
    // them, which no glyph ever shows.

    /// The colour in effect at each character of an ANSI-rendered line, as the
    /// SGR parameters that set it ("1;38;5;33"), or nil for the default.
    func decodeANSI(_ rendered: String) -> (plain: String, colors: [String?]) {
        var plain = ""
        var colors: [String?] = []
        var current: String?
        var index = rendered.startIndex

        while index < rendered.endIndex {
            if rendered[index] == "\u{1B}", rendered.index(after: index) < rendered.endIndex,
               rendered[rendered.index(after: index)] == "[" {
                var scan = rendered.index(index, offsetBy: 2)
                var parameters = ""
                while scan < rendered.endIndex, rendered[scan] != "m" {
                    parameters.append(rendered[scan])
                    scan = rendered.index(after: scan)
                }
                if scan < rendered.endIndex { scan = rendered.index(after: scan) }
                if parameters == "00" || parameters == "0" {
                    current = nil
                } else if parameters == "1" {
                    // Bold arrives as its own sequence, immediately before the
                    // colour it applies to.
                    current = "1"
                } else {
                    current = current == "1" ? "1;" + parameters : parameters
                }
                index = scan
                continue
            }
            plain.append(rendered[index])
            colors.append(current)
            index = rendered.index(after: index)
        }
        return (plain, colors)
    }

    /// The same colour, expressed the way the CLI expresses it.
    func ansiParameters(_ color: SQLColor?) -> String? { color?.ansi }

    func compareWithCLI(_ rendered: String, palette: SQLPalette, label: String) {
        let (plain, expected) = decodeANSI(rendered)
        let tokens = SQLSyntax.tokenize(plain, keywords: keywords)

        var actual = [String?](repeating: nil, count: expected.count)
        for token in tokens {
            guard let parameters = ansiParameters(palette.color(for: token.kind)) else { continue }
            for offset in token.location..<min(token.end, actual.count) {
                actual[offset] = parameters
            }
        }

        let characters = Array(plain)
        var mismatches: [String] = []
        for offset in 0..<expected.count where !characters[offset].isWhitespace {
            if expected[offset] != actual[offset] {
                mismatches.append("'\(characters[offset])' at \(offset): "
                                  + "CLI \(expected[offset] ?? "default") vs \(actual[offset] ?? "default")")
            }
        }
        expect(mismatches.isEmpty, "\(label) matches the CLI — \(mismatches.prefix(4).joined(separator: "; "))")
    }

    compareWithCLI(
        "\u{1B}[1m\u{1B}[38;5;33mSELECT \u{1B}[00m\u{1B}[38;5;220m'abc'\u{1B}[00m, "
        + "\u{1B}[38;5;212m42\u{1B}[00m, mycol \u{1B}[1m\u{1B}[38;5;33mFROM \u{1B}[00mtbl "
        + "\u{1B}[1m\u{1B}[38;5;33mWHERE \u{1B}[00my > \u{1B}[38;5;212m1 \u{1B}[00m"
        + "\u{1B}[90m-- note \u{1B}[00m",
        palette: .dark, label: "keywords, string, number, comment (dark)"
    )

    compareWithCLI(
        "\u{1B}[1m\u{1B}[38;5;27mSELECT \u{1B}[00m\u{1B}[38;5;58m'abc'\u{1B}[00m, "
        + "\u{1B}[38;5;90m42\u{1B}[00m, mycol \u{1B}[1m\u{1B}[38;5;27mFROM \u{1B}[00mtbl "
        + "\u{1B}[1m\u{1B}[38;5;27mWHERE \u{1B}[00my > \u{1B}[38;5;90m1 \u{1B}[00m"
        + "\u{1B}[90m-- note \u{1B}[00m",
        palette: .light, label: "keywords, string, number, comment (light)"
    )

    compareWithCLI(
        "\u{1B}[1m\u{1B}[38;5;33mSELECT \u{1B}[00m\u{1B}[38;5;212m1.5e3\u{1B}[00m, "
        + "\u{1B}[1m\u{1B}[38;5;33mTRUE\u{1B}[00m, \u{1B}[1m\u{1B}[38;5;33mNULL\u{1B}[00m, "
        + "x\u{1B}[1m\u{1B}[38;5;33m::\u{1B}[00m\u{1B}[1m\u{1B}[38;5;33mVARCHAR \u{1B}[00m",
        palette: .dark, label: "exponent, TRUE/NULL as keywords, :: (dark)"
    )

    compareWithCLI(
        "\u{1B}[1m\u{1B}[38;5;33mSELECT \u{1B}[00mcount(*) \u{1B}[1m\u{1B}[38;5;33mAS \u{1B}[00m"
        + "\"my col\" \u{1B}[1m\u{1B}[38;5;33mFROM \u{1B}[00mread_parquet("
        + "\u{1B}[38;5;220m'/a.parquet'\u{1B}[00m) ",
        palette: .dark, label: "functions and quoted identifiers stay uncoloured (dark)"
    )

    compareWithCLI(
        "\u{1B}[1m\u{1B}[38;5;33mSELECT \u{1B}[00m\u{1B}[38;5;203m'unterminated \u{1B}[00m",
        palette: .dark, label: "an unterminated string is the CLI's error colour (dark)"
    )

    compareWithCLI(
        "\u{1B}[1m\u{1B}[38;5;27mSELECT \u{1B}[00m\u{1B}[38;5;124m'unterminated \u{1B}[00m",
        palette: .light, label: "an unterminated string is the CLI's error colour (light)"
    )

    // The xterm indices above are only meaningful if they decode to the right
    // RGB, since that is what actually reaches the screen.
    expectEqual(SQLColor(xterm: 33).red, 0, "xterm 33 has no red")
    expectEqual(SQLColor(xterm: 33).green, 135.0 / 255, "xterm 33 is #0087FF")
    expectEqual(SQLColor(xterm: 33).blue, 1, "xterm 33 is full blue")
    expectEqual(SQLColor(xterm: 220).red, 1, "xterm 220 is #FFD700")
    expectEqual(SQLColor(xterm: 220).green, 215.0 / 255, "xterm 220's green")
    expectEqual(SQLColor(xterm: 220).blue, 0, "xterm 220 has no blue")
    expect(SQLPalette.dark.keyword.isBold && SQLPalette.light.keyword.isBold,
           "keywords are bold in both palettes, as the CLI's ESC[1m says")
    expect(SQLPalette.dark.plain == nil, "identifiers keep the editor's own text colour")

    // The documented deviation: the CLI leaves block comments uncoloured
    // because its tokenizer emits nothing for them. DuckParq colours them.
    expectEqual(SQLSyntax.tokenize("/* x */", keywords: keywords).map(\.kind), [.comment],
                "block comments are coloured here, unlike in the CLI")

    // The bootstrap set has to carry the app's own generated SQL convincingly
    // before the engine's list arrives.
    let generated = SQLBuilder.editableRows(
        source: .file(smallParquet),
        sort: [SortKey(column: "id", direction: .ascending)]
    )
    let withBootstrap = SQLSyntax.tokenize(generated, keywords: SQLKeywords.bootstrap)
    let withEngine = SQLSyntax.tokenize(generated, keywords: keywords)
    expectEqual(withBootstrap, withEngine, "generated SQL highlights identically before and after load")
}

// MARK: - Saved queries

section("Query library")

do {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-queries-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("by-score.sql")
    try QueryLibrary.save("SELECT * FROM t ORDER BY score DESC", to: file)
    expectEqual(try QueryLibrary.load(contentsOf: file),
                "SELECT * FROM t ORDER BY score DESC\n",
                "a saved query round-trips, with a trailing newline")

    let saved = SavedQuery(url: file)
    expectEqual(saved.name, "by-score", "the extension is not part of the name")

    // Round-tripping has to survive the characters that make quoting hard.
    let awkward = directory.appendingPathComponent("quotes.sql")
    let text = "SELECT * FROM read_parquet('/tmp/it''s here.parquet') WHERE s = 'a\"b'"
    try QueryLibrary.save(text, to: awkward)
    expectEqual(try QueryLibrary.load(contentsOf: awkward), text + "\n", "quoting survives a round trip")

    // A .sql file is arbitrary bytes from elsewhere, so loading is bounded.
    let huge = directory.appendingPathComponent("huge.sql")
    try Data(repeating: 0x41, count: QueryLibrary.maxFileBytes + 1).write(to: huge)
    do {
        _ = try QueryLibrary.load(contentsOf: huge)
        expect(false, "an oversized file is refused")
    } catch let error as QueryLibraryError {
        expectEqual(error, .tooLarge(bytes: QueryLibrary.maxFileBytes + 1, limit: QueryLibrary.maxFileBytes),
                    "the size limit names the actual size")
    } catch {
        expect(false, "an oversized file raises a library error, got \(error)")
    }

    let binary = directory.appendingPathComponent("binary.sql")
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: binary)
    do {
        _ = try QueryLibrary.load(contentsOf: binary)
        expect(false, "a non-text file is refused")
    } catch let error as QueryLibraryError {
        expectEqual(error, .notText, "non-UTF-8 content is named as such")
    } catch {
        expect(false, "a non-text file raises a library error, got \(error)")
    }

    expectEqual(QueryLibrary.suggestedName(for: .file(smallParquet)), "small",
                "the save panel starts from the file's name")
    expectEqual(QueryLibrary.suggestedName(for: nil), "query", "with no selection there is still a name")
}

// MARK: - Export

section("Export")

do {
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-export.csv")
    try? FileManager.default.removeItem(at: destination)

    let query = SQLBuilder.rows(source: .file(smallParquet), sort: [SortKey(column: "id", direction: .ascending)])
    let copy = SQLBuilder.export(query: query, to: destination, format: .csv, limit: 10)
    try await session.execute(copy.sql, params: copy.params)

    let written = try String(contentsOf: destination, encoding: .utf8)
    let lines = written.split(separator: "\n")
    expectEqual(lines.count, 11, "export writes a header plus the requested rows")
    expect(lines.first?.hasPrefix("id,category") == true, "export keeps column headers")
    try? FileManager.default.removeItem(at: destination)
}

// MARK: - TableModel (the logic the UI drives)

section("TableModel")

/// Wait for the model to settle, so assertions see a finished load.
@MainActor
func settle(_ model: TableModel, timeout: TimeInterval = 30) async {
    let deadline = Date().addingTimeInterval(timeout)
    // Give the reload a moment to start before watching for it to finish.
    try? await Task.sleep(for: .milliseconds(60))
    while Date() < deadline {
        // The row count runs alongside the first page, so a settled model means
        // all three are done -- otherwise assertions race the counter.
        if !model.isLoading && !model.isLoadingMore && !model.isCountingRows { return }
        try? await Task.sleep(for: .milliseconds(40))
    }
}

do {
    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "model-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "model-meta")
    )

    model.open(.file(smallParquet))
    await settle(model)

    if model.columns.count != 6 {
        FileHandle.standardError.write("  DIAGNOSTIC: cols=\(model.columns.count) rows=\(model.rows.count) loading=\(model.isLoading) counting=\(model.isCountingRows) err=\(model.errorMessage ?? "nil") total=\(String(describing: model.totalRowCount)) mode=\(model.mode)\n".data(using: .utf8)!)
    }
    expectEqual(model.columns.count, 6, "opening a file loads its schema")
    expectEqual(model.rows.count, TableModel.pageSize, "the first page is one page, not the whole file")
    expect(model.rows.count < 1000, "a preview is loaded rather than the entire file")
    expectEqual(model.totalRowCount, 1000, "the total row count is reported alongside the preview")
    expect(!model.reachedEnd, "500 of 1000 rows is not the end")

    // Scroll-driven paging.
    model.loadMoreIfNeeded(displayedIndex: model.rows.count - 1)
    await settle(model)
    expectEqual(model.rows.count, 1000, "scrolling to the end loads the next page")
    expect(model.reachedEnd, "a short final page marks the end of the stream")

    // Row ids must stay contiguous across pages, since the grid keys on them.
    expectEqual(model.rows.map(\.id), Array(0..<1000), "row ids stay contiguous across pages")

    // Three-state sort cycling, each step a fresh DuckDB query.
    let idIndex = model.columns.firstIndex { $0.name == "id" }!
    func firstID() -> String? { model.rows.first?.cells[idIndex] }

    expectEqual(firstID(), "0", "unsorted starts at the file's first row")

    model.toggleSort(column: "id")
    await settle(model)
    expectEqual(model.sortDirection(for: "id"), .ascending, "first click sorts ascending")
    expectEqual(firstID(), "0", "ascending starts at the lowest id")

    model.toggleSort(column: "id")
    await settle(model)
    expectEqual(model.sortDirection(for: "id"), .descending, "second click sorts descending")
    expectEqual(firstID(), "999", "descending starts at the highest id")

    model.toggleSort(column: "id")
    await settle(model)
    expectEqual(model.sortDirection(for: "id"), String?.none.map { _ in SortDirection.ascending },
                "third click clears the sort")
    expect(model.sort.isEmpty, "third click leaves no sort keys")

    // Sorting a numeric column must be numeric, not lexicographic — the check
    // that catches an accidental client-side or text sort.
    let scoreIndex = model.columns.firstIndex { $0.name == "score" }!
    model.toggleSort(column: "score")
    await settle(model)
    let firstScores = model.rows.prefix(12).map { Int($0.cells[scoreIndex] ?? "") ?? -1 }
    expect(firstScores == firstScores.sorted(), "ascending score is numerically ordered")
    expect(firstScores.first == 0, "ascending score starts at 0, not at \"0\" lexicographically")

    // Secondary sort keys.
    model.toggleSort(column: "category", additive: true)
    await settle(model)
    expectEqual(model.sort.count, 2, "shift-click adds a secondary sort key")
    expectEqual(model.sortOrdinal(for: "category"), 2, "the secondary key is numbered")

    // Filters restrict via DuckDB and reset the loaded window.
    model.clearSort()
    await settle(model)
    let categoryColumn = model.column(named: "category")!
    model.upsert(filter: Filter(column: categoryColumn, mode: .anyOf(["alpha"], includeNull: false)))
    await settle(model)
    expectEqual(model.totalRowCount, 250, "the filter reaches DuckDB")
    expectEqual(model.rows.count, 250, "the filtered result fits in one page")
    let categoryIndex = model.columns.firstIndex { $0.name == "category" }!
    expect(model.rows.allSatisfy { $0.cells[categoryIndex] == "alpha" }, "every visible row matches the filter")

    model.clearFilters()
    await settle(model)
    expectEqual(model.totalRowCount, 1000, "clearing filters restores the full count")

    // SQL mode.
    model.runSQL("SELECT category, count(*) AS n FROM read_parquet('\(smallParquet.path)') GROUP BY 1 ORDER BY 1")
    await settle(model)
    expectEqual(model.totalRowCount, 4, "SQL results report a total row count too")
    expect(model.isSQLMode, "running SQL switches the grid into SQL mode")
    expectEqual(model.columns.map(\.name), ["category", "n"], "SQL results define their own columns")
    expectEqual(model.rows.count, 4, "the aggregate returns one row per category")
    expectEqual(model.errorMessage, String?.none, "a valid query produces no error")

    // A bad query must surface a message and leave the app usable. It is
    // rejected before it runs, so the rows already on screen stay — there is no
    // reason to blank the grid over a query that never executed.
    model.runSQL("SELECT * FROM nonexistent_table_xyz")
    await settle(model)
    expect(model.errorMessage != nil, "invalid SQL surfaces DuckDB's error")
    expectEqual(model.rows.count, 4, "a rejected query leaves the previous result visible")

    // Writes never reach the engine, whichever way they are dressed up. This is
    // the same guarantee as the policy section, asserted on the path the UI
    // actually calls.
    for sql in [
        "DROP VIEW t",
        "COPY (SELECT 1) TO '/tmp/duckparq-selftest-should-not-exist.csv'",
        "SELECT 1; DROP VIEW t",
        "ATTACH '/tmp/duckparq-selftest.db' AS e",
    ] {
        model.runSQL(sql)
        await settle(model)
        expect(model.errorMessage != nil, "runSQL refuses: \(sql)")
        expectEqual(model.isSQLMode, true, "a refused query does not change what the grid is showing")
    }
    expect(
        !FileManager.default.fileExists(atPath: "/tmp/duckparq-selftest-should-not-exist.csv"),
        "the refused COPY wrote nothing to disk"
    )

    // Recovering afterwards must work — the error is not sticky.
    model.open(.file(smallParquet))
    await settle(model)
    expectEqual(model.errorMessage, String?.none, "selecting a file clears the previous error")
    expectEqual(model.rows.count, TableModel.pageSize, "the grid works again after an error")

    // Rapid re-sorting: only the final ordering may survive. This is the
    // generation guard plus interrupt working together.
    model.toggleSort(column: "id")            // ascending
    model.toggleSort(column: "id")            // descending
    model.toggleSort(column: "score")         // replace with score ascending
    await settle(model)
    expectEqual(model.sort.map(\.column), ["score"], "rapid sort changes leave only the last one")
    let settled = model.rows.prefix(6).map { Int($0.cells[scoreIndex] ?? "") ?? -1 }
    expect(settled == settled.sorted(), "the surviving result matches the final sort, not a stale one")
}

// MARK: - Scale

// Only meaningful against the 10M-row fixture (`BIG=1 make fixtures`), which is
// large enough that "preview, don't load the file" and "cancel actually stops"
// are testable rather than assumed.
let bigParquet = fixtures.appendingPathComponent("big.parquet")
if FileManager.default.fileExists(atPath: bigParquet.path) {
    section("Scale (10M rows)")

    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "big-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "big-meta")
    )

    // Opening a big file must show rows quickly, not read 10M of them.
    let openedAt = Date()
    model.open(.file(bigParquet))
    await settle(model)
    let openElapsed = Date().timeIntervalSince(openedAt)

    expectEqual(model.rows.count, TableModel.pageSize, "a 10M-row file still previews one page")
    // The whole point of the count: report rows that were never fetched.
    expectEqual(model.totalRowCount, 10_000_000, "the total counts rows far beyond those loaded")
    expect((model.totalRowCount ?? 0) > model.rows.count * 1000,
           "the total is the file's size, not the loaded preview")
    expect(openElapsed < 5, "opening a 10M-row file is fast (took \(String(format: "%.2f", openElapsed))s)")
    print("  open: \(String(format: "%.2f", openElapsed))s")

    // Paging continues the same stream, so later pages stay cheap.
    let pageAt = Date()
    for _ in 0..<4 {
        model.loadMore()
        await settle(model)
    }
    let pageElapsed = Date().timeIntervalSince(pageAt)
    expectEqual(model.rows.count, TableModel.pageSize * 5, "four more pages append to the stream")
    expect(pageElapsed < 5, "paging stays cheap (4 pages in \(String(format: "%.2f", pageElapsed))s)")
    print("  4 more pages: \(String(format: "%.2f", pageElapsed))s")

    // Sorting 10M rows is a real sort; it must be pushed down and correct.
    let sortAt = Date()
    model.toggleSort(column: "measure")
    await settle(model)
    let sortElapsed = Date().timeIntervalSince(sortAt)
    let measureIndex = model.columns.firstIndex { $0.name == "measure" }!
    let head = model.rows.prefix(20).map { Double($0.cells[measureIndex] ?? "") ?? -1 }
    expect(head == head.sorted(), "a 10M-row sort returns rows in order")
    print("  sort 10M rows: \(String(format: "%.2f", sortElapsed))s")

    // Cross-check the top row against DuckDB itself, so a subtly wrong ORDER BY
    // can't pass just by being internally consistent.
    let verifier = try DuckDBSession(engine: engine, label: "verify")
    let expected = try await verifier.queryAll(
        "SELECT measure FROM read_parquet($1) ORDER BY measure LIMIT 1",
        params: [bigParquet.path], limit: 1)
    expectEqual(model.rows.first?.cells[measureIndex], expected[0, 0],
                "the grid's first sorted row matches DuckDB's own ORDER BY")

    // Re-sorting mid-scan must abandon the previous sort promptly.
    let cancelAt = Date()
    model.toggleSort(column: "key")     // starts a fresh 10M sort
    model.toggleSort(column: "bucket")  // immediately supersedes it
    await settle(model)
    let cancelElapsed = Date().timeIntervalSince(cancelAt)
    expectEqual(model.sort.map(\.column), ["bucket"], "only the final sort survives")
    expect(model.rows.count > 0, "the surviving sort produced rows")
    print("  superseded re-sort settled in: \(String(format: "%.2f", cancelElapsed))s")
} else {
    print("\n— Scale: skipped (run `BIG=1 make fixtures` for the 10M-row file)")
}

// MARK: - Summary

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ok")
