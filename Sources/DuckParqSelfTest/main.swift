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

    // A hive layout is one table whose partitions are columns. Listing
    // `year=2024/` as a folder invites opening a slice of a dataset as though
    // it were a thing in its own right, so the partitions are withheld and the
    // folder is offered whole.
    let hiveListing = FileTree.listing(of: hiveDirectory)
    expectEqual(hiveListing.outcome, .hivePartitioned, "a hive folder says why it lists no sub-folders")
    expect(!hiveListing.nodes.contains { $0.isDirectory }, "partition directories are withheld")
    expect(FileTree.isHivePartitioned(hiveDirectory), "the hive layout is detected")
    expect(!FileTree.isHivePartitioned(fixtures),
           "a plain folder of parquet files is not hive-partitioned")
    expect(FileTree.children(of: hiveDirectory).isEmpty,
           "nothing under a hive folder is offered for browsing")
    expect(FileTree.isHivePartitionName("year=2024"), "key=value is a partition name")
    expect(!FileTree.isHivePartitionName("=2024"), "a value with no key is not a partition name")
    expect(!FileTree.isHivePartitionName("plain"), "a folder without = is not a partition")

    // Search must not descend into partitions either, or a hive dataset floods
    // the results with a file per partition.
    expect(FileTree.search(root: hiveDirectory, query: "data").isEmpty,
           "search does not reach into hive partitions")

    let datasetSource = DataSource.dataset(hiveDirectory)
    expect(datasetSource.readPath.hasSuffix("/**/*.parquet"), "datasets read recursively")

    // With the partitions withheld, the sidebar's only way to open a hive
    // folder is the note explaining why — so tapping it has to resolve to the
    // exact same dataset "All files as one dataset" would open.
    let hiveNoteNode = FileNode(url: hiveDirectory, isDirectory: true, isDataset: true,
                                 byteSize: nil, modified: nil)
    expectEqual(hiveNoteNode.dataSource, .dataset(hiveDirectory),
                "tapping the hive-partitioned note opens the whole folder as one dataset")
}

// MARK: - Sifting a drop

section("Dropped files")

do {
    // A drop carries whatever Finder had selected, which is anything at all.
    let dropped = [
        fixtures.appendingPathComponent("does-not-exist.txt"),
        hiveDirectory,
        smallParquet,
        typesParquet,
    ]
    expectEqual(FileTree.parquetFiles(in: dropped).map(\.lastPathComponent),
                ["small.parquet", "types.parquet"],
                "only parquet files survive a drop, in the order dragged")
    expect(FileTree.parquetFiles(in: [hiveDirectory]).isEmpty,
           "a folder is not a file to open, whatever it holds")
    expect(FileTree.parquetFiles(in: []).isEmpty, "an empty drop yields nothing")

    // The other two extensions the bundle claims have to be honoured here too,
    // or a file Finder handed over on a double-click would be refused on a drop.
    let alternatives = ["a.pq", "b.parq", "c.PARQUET"].map(URL.init(fileURLWithPath:))
    expectEqual(FileTree.parquetFiles(in: alternatives).count, 3,
                "every claimed extension is accepted, whatever its case")
    expect(FileTree.parquetFiles(in: [URL(fileURLWithPath: "/x/notes.csv")]).isEmpty,
           "a file that is not parquet is refused")

    // A directory named like a file is still a directory.
    let trap = fixtures.appendingPathComponent("looks-like-a-file.parquet")
    try? FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)
    expect(FileTree.parquetFiles(in: [trap]).isEmpty,
           "a folder named .parquet is not mistaken for a file")
    try? FileManager.default.removeItem(at: trap)

    // The other half of the sift: a dropped folder is a folder to browse, so
    // one drop can both add a root and open a file.
    expectEqual(FileTree.directories(in: dropped).map(\.lastPathComponent),
                [hiveDirectory.lastPathComponent],
                "only folders survive as folders, in the order dragged")
    expect(FileTree.directories(in: [smallParquet]).isEmpty,
           "a file is not a folder to add")
    expect(FileTree.directories(in: []).isEmpty, "an empty drop yields no folders")

    // Neither half is asked to guess: existence is read from disk, not from the
    // name, so a folder called .parquet is added and a missing path is neither.
    let namedLikeAFile = fixtures.appendingPathComponent("looks-like-a-file.parquet")
    try? FileManager.default.createDirectory(at: namedLikeAFile, withIntermediateDirectories: true)
    expectEqual(FileTree.directories(in: [namedLikeAFile]).count, 1,
                "a folder named .parquet is still a folder to browse")
    try? FileManager.default.removeItem(at: namedLikeAFile)
    expect(FileTree.directories(in: [fixtures.appendingPathComponent("gone")]).isEmpty,
           "a path that is not there is not a folder")
}

// MARK: - Locating a file in the added roots
//
// What the sidebar needs to open a file handed over by Finder: which added
// folder it belongs to, and which folders have to be expanded to put it on
// screen.

section("Reveal in the tree")

do {
    let data = URL(fileURLWithPath: "/data")
    let deep = URL(fileURLWithPath: "/data/2024/q1/sales.parquet")

    expect(FileTree.contains(data, deep), "a file below an added folder is found in it")
    expect(!FileTree.contains(deep, data), "containment is not symmetric")
    expect(!FileTree.contains(data, data), "a folder does not contain itself")

    // A string prefix test says /data contains /database — the sidebar would
    // then expand a folder the file is not in, and never show the file.
    expect(!FileTree.contains(data, URL(fileURLWithPath: "/database/x.parquet")),
           "a folder is not matched by a name it merely starts")
    expect(!FileTree.contains(URL(fileURLWithPath: "/data/sales"),
                              URL(fileURLWithPath: "/data/sales-2024/x.parquet")),
           "sibling folders sharing a prefix stay separate")

    expectEqual(FileTree.relativeComponents(of: deep, under: data) ?? [],
                ["2024", "q1", "sales.parquet"],
                "the descent from the folder to the file is reported in full")

    // A directory listing yields file:///a/b/ where an open panel yields
    // file:///a/b. Those two URLs are not equal, so the comparison cannot be
    // one — the roots come from the panel and the folders below from listings.
    expect(FileTree.contains(URL(fileURLWithPath: "/data", isDirectory: true), deep),
           "a trailing slash on the folder does not hide the file")

    // Finder passes /private/tmp/… for a folder added as /tmp/…, and only the
    // resolved forms match. The second case is the harder one: a path whose
    // leaf does not exist resolves to itself, symlinked directory and all.
    expect(FileTree.contains(URL(fileURLWithPath: "/etc"),
                             URL(fileURLWithPath: "/private/etc/hosts")),
           "a symlinked folder contains a file Finder names differently")
    expect(FileTree.contains(URL(fileURLWithPath: "/tmp"),
                             URL(fileURLWithPath: "/private/tmp/gone.parquet")),
           "and still does when the file itself is no longer there")

    // The deepest added folder wins: it is the shorter trip to the row.
    let roots = [data, URL(fileURLWithPath: "/data/2024"), URL(fileURLWithPath: "/elsewhere")]
    expectEqual(FileTree.root(containing: deep, in: roots)?.path, "/data/2024",
                "the nearest added folder is the one to reveal in")
    expect(FileTree.root(containing: URL(fileURLWithPath: "/other/x.parquet"), in: roots) == nil,
           "a file under no added folder has no root")
    expect(FileTree.root(containing: deep, in: []) == nil, "with no folders added there is no root")

    expectEqual(FileTree.ancestors(of: deep, upTo: data).map(\.path),
                ["/data", "/data/2024", "/data/2024/q1"],
                "every folder down to the file's own is expanded, the file itself is not")
    expectEqual(FileTree.ancestors(of: URL(fileURLWithPath: "/data/top.parquet"), upTo: data).map(\.path),
                ["/data"],
                "a file directly in the added folder needs only that folder open")
    expect(FileTree.ancestors(of: deep, upTo: URL(fileURLWithPath: "/elsewhere")).isEmpty,
           "a file outside the folder has nothing to expand")

    // The expanded URLs are compared against ones the sidebar built from a
    // directory listing, so they have to be spelled the same way.
    let listed = fixtures.appendingPathComponent("hive")
    let chain = FileTree.ancestors(of: listed.appendingPathComponent("x.parquet"), upTo: fixtures)
    expect(chain.contains(listed),
           "an expanded folder equals the URL a directory listing produces")
    expect(Set(FileTree.children(of: fixtures).map(\.url)).isSuperset(of: [listed]),
           "and that URL is in fact what the listing produced")
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

// MARK: - Horizontal virtualization
//
// The grid draws only the columns the viewport is over. Getting the range
// wrong is not a slow grid but a wrong one: cells would sit under the wrong
// headers, or scroll off before the edge of the window. The offsets are the
// single source of truth for both, so they are what these check.

do {
    let widths: [CGFloat] = [100, 200, 50, 300, 75]
    let offsets = ColumnLayout.offsets(for: widths)

    expectEqual(offsets.count, widths.count + 1, "there is one offset per column plus the total")
    expectEqual(offsets, [0, 100, 300, 350, 650, 725], "offsets are the running sum of the widths")
    expectEqual(offsets.last, widths.reduce(0, +), "the last offset is the full content width")
    expectEqual(ColumnLayout.offsets(for: []), [0], "no columns still yields a zero total")

    // Without overscan the range is exactly the columns the viewport touches.
    // Checked with overscan 0 because that is the property that has to hold;
    // the overscan is padding around it, not part of the answer.
    expectEqual(ColumnLayout.visibleRange(offsets: offsets, x: 0, width: 100, overscan: 0), 0..<1,
                "a viewport over the first column shows only it")
    expectEqual(ColumnLayout.visibleRange(offsets: offsets, x: 0, width: 350, overscan: 0), 0..<3,
                "a viewport spanning three columns shows all three")
    expectEqual(ColumnLayout.visibleRange(offsets: offsets, x: 310, width: 100, overscan: 0), 2..<4,
                "scrolled past the start, the range begins at the column under the left edge")
    expectEqual(ColumnLayout.visibleRange(offsets: offsets, x: 700, width: 100, overscan: 0), 4..<5,
                "a viewport past the end of the content clamps to the last column")

    // A column partly over the left edge is still on screen — dropping it would
    // leave a blank strip where its remaining sliver should be.
    let straddling = ColumnLayout.visibleRange(offsets: offsets, x: 150, width: 100, overscan: 0)
    expect(straddling.contains(1), "a column straddling the left edge is included")

    let padded = ColumnLayout.visibleRange(offsets: offsets, x: 310, width: 100, overscan: 2)
    expectEqual(padded, 0..<5, "overscan widens the range and stays inside the columns that exist")

    expectEqual(ColumnLayout.visibleRange(offsets: [0], x: 0, width: 500), 0..<0,
                "a grid with no columns has nothing to show")
    expectEqual(ColumnLayout.visibleRange(offsets: offsets, x: 0, width: 0), 0..<0,
                "a viewport with no width has nothing to show")

    // Whatever the scroll position, the drawn columns start exactly where the
    // omitted ones end — that offset is the spacer the header and every row put
    // in front of their cells, and it is what keeps the two aligned.
    for x in stride(from: CGFloat(0), through: 725, by: 25) {
        let range = ColumnLayout.visibleRange(offsets: offsets, x: x, width: 200)
        expect(range.lowerBound >= 0 && range.upperBound <= widths.count,
               "the visible range stays within the columns at x=\(Int(x))")
        let drawn = widths[range].reduce(0, +)
        expectEqual(offsets[range.lowerBound] + drawn, offsets[range.upperBound],
                    "the leading spacer plus the drawn columns reach the end of the range at x=\(Int(x))")
    }

    // Turning a pointer position back into a cell. The cells are drawn rather
    // than laid out as views, so this is the only thing standing between a
    // right-click and the wrong column's filter.
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: 0), 0,
                "the left edge is the first column")
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: 99), 0,
                "a point inside the first column is the first column")
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: 100), 1,
                "a point on a boundary belongs to the column it starts")
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: 349), 2,
                "a point inside a narrow column is that column")
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: 724), 4,
                "a point in the last column is the last column")
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: 5_000), 4,
                "a point past the content clamps to the last column")
    expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: -20), 0,
                "a point before the content clamps to the first column")
    expect(ColumnLayout.columnIndex(offsets: [0], at: 10) == nil,
           "a grid with no columns has no column under the pointer")

    // Every point in a column's span must resolve to that column, or a menu
    // would sometimes act on the neighbour.
    for index in 0..<widths.count {
        let start = offsets[index]
        for x in stride(from: start, to: offsets[index + 1], by: 7) {
            expectEqual(ColumnLayout.columnIndex(offsets: offsets, at: x), index,
                        "x=\(Int(x)) falls in column \(index)")
        }
    }

    // Wide files are the case this exists for: a thousand columns must cost a
    // screenful of cells, not a thousand.
    let many = [CGFloat](repeating: 80, count: 1_000)
    let manyOffsets = ColumnLayout.offsets(for: many)
    let onScreen = ColumnLayout.visibleRange(offsets: manyOffsets, x: 40_000, width: 1_200)
    expect(onScreen.count < 30, "a thousand-column grid draws a screenful, not the file")
    expect(onScreen.contains(500), "the range covers the column under the left edge")
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
    if case .dropdown(let values, let nullCount) = affordance {
        expectEqual(values.map(\.value), ["alpha", "beta", "delta", "gamma"],
                    "low-cardinality column offers its values")
        expectEqual(values.map(\.count), [250, 250, 250, 250],
                    "each value carries how many rows have it")
        expectEqual(nullCount, 0, "no NULLs in the category fixture")
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
        // Named rather than four inline literals: untyped integer literals in a
        // chain of `||` make the solver try every integer type against every
        // comparison, which Swift 6.1 gives up on. A typed Set is one concrete
        // call, and says what the numbers are.
        let blank: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D]  // space, tab, LF, CR
        let gapsAreBlank = zip(units, covered).allSatisfy { unit, isCovered in
            isCovered || blank.contains(unit)
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

// MARK: - SQL formatting

section("SQL formatting")

do {
    let keywords = SQLKeywords.shared.all

    /// The formatter's whole contract, checked rather than asserted in a
    /// comment: the token stream out is the token stream in. Anything that
    /// changed a literal, dropped a clause or split `<=` fails here.
    func tokenStream(_ text: String) -> [String] {
        SQLSyntax.tokenize(text, keywords: keywords).map { token in
            let range = NSRange(location: token.location, length: token.length)
            return "\(token.kind):\((text as NSString).substring(with: range))"
        }
    }

    let samples = [
        "select a,b from t where x>1 and y<2 order by a desc",
        "SELECT * FROM read_parquet('/tmp/it''s.parquet') AS t WHERE t.\"a b\" <= 1.5",
        "SELECT a FROM t WHERE x BETWEEN 1 AND 10 AND y = 2",
        "SELECT CASE WHEN a > 1 THEN 'big' ELSE 'small' END AS size FROM t",
        "SELECT * FROM (SELECT id FROM t WHERE id > 5) ORDER BY id",
        "SELECT count(*) FROM t LEFT OUTER JOIN u ON t.id = u.id WHERE t.x <> 1",
        "SELECT 'a -- not a comment', 1 -- but this is\nFROM t",
        "SELECT /* a /* nested */ b */ 1",
        "SELECT $1, x$1 FROM t",
        "SELECT a-1, -1, a - -1, a::VARCHAR FROM t",
        "SELECT left('abc', 1), a[1] FROM t",
        "SELECT 1;",
        "",
        "   \n\t ",
        "SELECT 'unterminated",
        "--",
    ]

    for sample in samples {
        let formatted = SQLFormatter.format(sample, keywords: keywords)
        expectEqual(tokenStream(formatted), tokenStream(sample),
                    "formatting only moves whitespace: \(sample.prefix(46))")
        // A second pass must be a no-op, or the button's effect depends on how
        // many times it was pressed.
        expectEqual(SQLFormatter.format(formatted, keywords: keywords), formatted,
                    "formatting is idempotent: \(sample.prefix(46))")
    }

    // Layout, on the case the Format button actually gets pressed on.
    do {
        let formatted = SQLFormatter.format(
            "select a,b from t where x>1 and y<2 order by a desc", keywords: keywords)
        let lines = formatted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        expectEqual(lines, [
            "select",
            "  a,",
            "  b",
            "from t",
            "where x > 1",
            "  and y < 2",
            "order by a desc",
        ], "clauses start lines, list items and conjunctions are indented under them")
    }

    // `BETWEEN x AND y` reads as one condition, so its AND must not be broken
    // out as though it were a second predicate.
    do {
        let formatted = SQLFormatter.format("SELECT a FROM t WHERE x BETWEEN 1 AND 10 AND y = 2",
                                            keywords: keywords)
        expect(formatted.contains("BETWEEN 1 AND 10"), "BETWEEN keeps its AND on the line")
        expect(formatted.contains("\n  AND y = 2"), "the real conjunction still breaks")
    }

    // A single-item SELECT stays on its line; only a list gets a heading.
    expect(SQLFormatter.format("SELECT * FROM t", keywords: keywords).hasPrefix("SELECT *"),
           "a one-item select list is not split from its keyword")

    // The one that matters most: formatting a query does not change what it
    // returns. Checked by running both, not by comparing strings.
    do {
        let original = SQLBuilder.editableRows(
            source: .file(smallParquet),
            filters: [Filter(column: scoreColumn, mode: .comparison(.greaterThan, ["900"]))],
            sort: [SortKey(column: "id", direction: .descending)]
        )
        let formatted = SQLFormatter.format(original, keywords: keywords)
        expect(formatted != original, "the generated query is actually reformatted")

        let before = try await session.queryAll(original)
        let after = try await session.queryAll(formatted)
        expectEqual(after.columns, before.columns, "formatting preserves the result's columns")
        expectEqual(after.rowCount, before.rowCount, "formatting preserves the row count")
        expectEqual(after.cells, before.cells, "formatting preserves every cell")
    }

    // Formatted output has to survive the read-only check, since Format sits
    // next to Run and people will press them in that order.
    do {
        let formatted = SQLFormatter.format(
            "select id from read_parquet('\(smallParquet.path)') where id>1", keywords: keywords)
        try await session.validateReadOnly(formatted)
        expect(true, "formatted SQL still parses as a single read-only statement")
    }
}

// MARK: - Row window

section("Row window")

do {
    let sorted = SQLBuilder.rows(
        source: .file(smallParquet),
        sort: [SortKey(column: "id", direction: .ascending)]
    )

    // The window is applied on top of the query, never folded into it: export
    // means every matching row, and the SQL offered in the editor must not
    // carry a limit the user did not write.
    expect(!sorted.sql.uppercased().contains("LIMIT"), "the query itself is unbounded")
    let windowed = SQLBuilder.windowed(sorted, limit: TableModel.pageSize)
    expect(windowed.sql.hasSuffix("LIMIT 500"), "the window is a real LIMIT clause")
    expectEqual(windowed.params, sorted.params, "windowing binds no new parameters")

    // The entire point of the clause: DuckDB must plan a sorted, limited query
    // as a Top-N, keeping 500 rows as it scans. Without that it materialises and
    // orders the whole result before producing a first row, which is the
    // difference between browsing a three-billion-row dataset and waiting for it
    // to be sorted. Asserted against the engine's own plan, since it is a
    // property of DuckDB's optimiser and not of anything written here.
    // Read verbatim: an EXPLAIN cannot go through the bridge's VARCHAR wrap
    // either, for exactly the reason it cannot be windowed.
    let planCursor = try await session.openCursor(
        "EXPLAIN " + windowed.sql, params: windowed.params, renderAsText: false)
    var planText = ""
    while let page = try await planCursor.fetch(maxRows: 256) {
        planText += page.cells.compactMap { $0 }.joined(separator: "\n")
    }
    await planCursor.close()
    expect(planText.contains("TOP_N"), "a sorted window plans as Top-N")
    expect(!planText.contains("ORDER_BY"), "no separate full ordering survives in the plan")

    // And the limit really does pass through the wrapper.
    let bounded = try await session.queryAll(windowed.sql, params: windowed.params)
    expectEqual(bounded.rowCount, TableModel.pageSize, "the window bounds what comes back")

    // Every read-only statement the policy admits has to survive being wrapped,
    // because that is what the grid does to whatever is in the editor. EXPLAIN
    // is the one that cannot be selected from, which is why TableModel checks
    // the parsed kind rather than the text.
    for statement in [
        "SELECT 1 AS a",
        "DESCRIBE SELECT 1 AS a",
        "SUMMARIZE SELECT 1 AS a",
        "SHOW TABLES",
        "VALUES (1), (2)",
        "WITH x AS (SELECT 1 AS a) SELECT * FROM x",
        "FROM range(3)",
    ] {
        let wrapped = SQLBuilder.windowed(BoundSQL(sql: statement, params: []), limit: 5)
        do {
            _ = try await session.queryAll(wrapped.sql, limit: 5)
        } catch {
            expect(false, "a windowed \(statement) still runs, got \(error)")
        }
    }
    expect(true, "every wrappable read-only form survives the window")

    do {
        let wrapped = SQLBuilder.windowed(BoundSQL(sql: "EXPLAIN SELECT 1", params: []), limit: 5)
        let cursor = try await session.openCursor(wrapped.sql, renderAsText: false)
        await cursor.close()
        expect(false, "wrapping an EXPLAIN is expected to fail, so the model must not do it")
    } catch {
        expect(true, "EXPLAIN cannot be windowed, which is why it is exempted by parsed kind")
    }

    // Run verbatim, it works — which is the whole reason the exemption exists
    // rather than EXPLAIN simply being refused.
    do {
        let cursor = try await session.openCursor("EXPLAIN SELECT 1", renderAsText: false)
        let page = try await cursor.fetch(maxRows: 64)
        await cursor.close()
        expect((page?.rowCount ?? 0) > 0, "an unwrapped EXPLAIN returns its plan")
    } catch {
        expect(false, "an unwrapped EXPLAIN runs, got \(error)")
    }
}

// MARK: - Distinct value probe

section("Distinct values")

do {
    let categoryColumn = ColumnInfo(name: "category", typeName: "VARCHAR")
    let query = SQLBuilder.distinctValues(source: .file(smallParquet), column: categoryColumn)
    expect(query.sql.contains("SELECT DISTINCT"),
           "the probe asks for distinct values rather than counting occurrences")
    expect(!query.sql.uppercased().contains("GROUP BY"),
           "no aggregate is computed for a result that only needs the values")
    expectEqual(query.params, [smallParquet.path], "the path is still bound, not interpolated")

    let batch = try await session.queryAll(query.sql, params: query.params, limit: 64)
    expectEqual(batch.rowCount, 4, "the low-cardinality column reports its four values")
    expectEqual(batch.column("value").compactMap { $0 }.sorted(),
                ["alpha", "beta", "delta", "gamma"],
                "and they are the actual values, not counts")

    // Above the cap the probe must return one more than the maximum, which is
    // how the caller tells "too many to enumerate" from "exactly the maximum".
    let idColumn = ColumnInfo(name: "id", typeName: "BIGINT")
    let wide = SQLBuilder.distinctValues(source: .file(smallParquet), column: idColumn, maxDistinct: 50)
    let wideBatch = try await session.queryAll(wide.sql, params: wide.params, limit: 128)
    expectEqual(wideBatch.rowCount, 51, "a high-cardinality column stops one past the cap")

    // The affordance those queries feed, end to end.
    let probe = Probe(session: session)
    if case .dropdown(let values, _) =
        try await probe.filterAffordance(for: categoryColumn, in: .file(smallParquet)) {
        expectEqual(values.map(\.value), ["alpha", "beta", "delta", "gamma"],
                    "a low-cardinality column offers a list, sorted for reading")
    } else {
        expect(false, "a four-value column gets a dropdown")
    }
    expectEqual(try await probe.filterAffordance(for: idColumn, in: .file(smallParquet)), .comparison,
                "a column with a thousand values gets comparison operators instead")

    // The cap itself, from both sides. A boundary this arbitrary is exactly the
    // kind that drifts by one between the SQL `LIMIT` and the Swift comparison.
    expectEqual(Probe.defaultMaxDistinct, 500, "checkboxes are offered up to five hundred values")
    let boundary = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-boundary-\(UUID().uuidString).parquet")
    defer { try? FileManager.default.removeItem(at: boundary) }
    try await session.execute("""
        COPY (
            SELECT (i % 500)::VARCHAR AS at_cap, (i % 501)::VARCHAR AS past_cap
            FROM range(20000) t(i)
        ) TO '\(boundary.path)' (FORMAT parquet)
        """)
    if case .dropdown(let values, let nullCount) = try await probe.filterAffordance(
        for: ColumnInfo(name: "at_cap", typeName: "VARCHAR"), in: .file(boundary)) {
        expectEqual(values.count, 500, "a column with exactly the cap still gets a list")
        expectEqual(nullCount, 0, "and no NULLs to account for")
        expectEqual(values.map(\.count).reduce(0, +), 20000, "with counts covering every row")
    } else {
        expect(false, "500 distinct values is at the cap, not past it")
    }
    expectEqual(try await probe.filterAffordance(
        for: ColumnInfo(name: "past_cap", typeName: "VARCHAR"), in: .file(boundary)),
        .comparison, "one value past the cap falls back to comparison operators")

    // The case that made this wrong: a low-cardinality column whose leading
    // rows are all NULL. Reading the head and showing what it found reported an
    // empty list — a caveat where the answer should have been. Real parquet is
    // full of these; every flag column in a weather dataset looks like this.
    let sparse = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-sparse-\(UUID().uuidString).parquet")
    defer { try? FileManager.default.removeItem(at: sparse) }
    try await session.execute("""
        COPY (
            SELECT i AS id,
                   CASE WHEN i < 400000 THEN NULL
                        ELSE ['alpha', 'beta', 'gamma'][(i % 3) + 1] END AS flag
            FROM range(420000) t(i)
        ) TO '\(sparse.path)' (FORMAT parquet)
        """)

    let flagColumn = ColumnInfo(name: "flag", typeName: "VARCHAR")
    let headOnly = SQLBuilder.distinctValues(
        source: .file(sparse), column: flagColumn, sampleRows: 200_000)
    let headBatch = try await session.queryAll(headOnly.sql, params: headOnly.params, limit: 64)
    expectEqual(headBatch.rowCount, 1, "the head of this column really is nothing but NULL")

    if case .dropdown(let values, let nullCount) =
        try await probe.filterAffordance(for: flagColumn, in: .file(sparse)) {
        expectEqual(values.map(\.value), ["alpha", "beta", "gamma"],
                    "the dropdown lists the column's values, not the head's")
        expectEqual(nullCount, 400_000, "and counts the NULLs it found rather than just noting them")
        expectEqual(values.map(\.count).reduce(0, +) + nullCount, 420_000,
                    "the counts account for every row in the column")
    } else {
        expect(false, "a three-value column gets a dropdown however its rows are ordered")
    }

    // The bounded read can still reject, which is what keeps the exact question
    // off high-cardinality columns: more distinct values in a subset proves more
    // distinct values overall, so rejection is sound where admission would not be.
    expectEqual(try await probe.filterAffordance(for: ColumnInfo(name: "id", typeName: "BIGINT"),
                                                 in: .file(sparse)),
                .comparison, "a column with 420,000 values is still rejected cheaply")

    // The same shape on the path a real dataset takes: many files, read through
    // hive_partitioning and union_by_name rather than as one file. The early
    // partitions hold nothing but NULL, exactly as a year-partitioned archive
    // does for a flag column that older records never carried.
    let partitioned = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-partitioned-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: partitioned) }
    try await session.execute("""
        COPY (
            SELECT i AS id,
                   1750 + (i / 60000)::INTEGER AS year,
                   CASE WHEN i < 300000 THEN NULL
                        ELSE ['T', 'B', 'D', 'H'][(i % 4) + 1] END AS m_flag
            FROM range(420000) t(i)
        ) TO '\(partitioned.path)' (FORMAT parquet, PARTITION_BY (year))
        """)

    let dataset = DataSource.dataset(partitioned)
    let flagInDataset = ColumnInfo(name: "m_flag", typeName: "VARCHAR")
    if case .dropdown(let values, let nullCount) =
        try await probe.filterAffordance(for: flagInDataset, in: dataset) {
        expectEqual(values.map(\.value), ["B", "D", "H", "T"],
                    "a sparse flag column across many partitions lists all its values")
        expectEqual(nullCount, 300_000, "including that most of the archive has none")
        expectEqual(values.map(\.count).reduce(0, +) + nullCount, 420_000,
                    "counts across partitions add up to the whole dataset")
    } else {
        expect(false, "a four-value column in a hive dataset gets a dropdown")
    }

    // A dropdown must never be empty — an empty list is indistinguishable from
    // a broken popover, which is what this looked like on screen.
    let empty = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-empty-\(UUID().uuidString).parquet")
    defer { try? FileManager.default.removeItem(at: empty) }
    try await session.execute(
        "COPY (SELECT NULL::VARCHAR AS flag WHERE false) TO '\(empty.path)' (FORMAT parquet)")
    expectEqual(try await probe.filterAffordance(for: ColumnInfo(name: "flag", typeName: "VARCHAR"),
                                                 in: .file(empty)),
                .comparison, "a column with no values at all offers comparison, not an empty list")
}

// MARK: - Value completion

section("Filter value completion")

do {
    // The lookup itself, against a list with a known shape. It is a lower
    // bound, not a prefix match: what a half-typed value wants offered is where
    // it lands among the column's values, and a prefix match has nothing to say
    // the moment a typo takes it off the list.
    let index = DistinctValueIndex(
        values: ["alpha", "beta", "delta", "epsilon", "gamma"], isComplete: true)

    expectEqual(index.suggestions(startingAt: "b"), ["beta", "delta", "epsilon", "gamma"],
                "completions start where the typed text lands")
    expectEqual(index.suggestions(startingAt: ""), index.values,
                "an empty field is offered the column's first values")
    expectEqual(index.suggestions(startingAt: "beta").first, "beta",
                "a value already typed in full completes to itself, not the next one along")
    expectEqual(index.suggestions(startingAt: "c"), ["delta", "epsilon", "gamma"],
                "text matching nothing still lands somewhere rather than offering nothing")
    expect(index.suggestions(startingAt: "z").isEmpty, "past the last value there is nothing to offer")
    expectEqual(index.suggestions(startingAt: "", limit: 2), ["alpha", "beta"],
                "the list is capped at the limit asked for")
    expect(DistinctValueIndex(values: [], isComplete: true).suggestions(startingAt: "a").isEmpty,
           "an empty index offers nothing rather than trapping")
    expectEqual(DistinctValueIndex.suggestionLimit, 10, "ten completions are offered")
}

do {
    let query = SQLBuilder.orderedDistinctValues(
        source: .file(smallParquet), column: labelColumn, limit: 10)
    expect(query.sql.contains("ORDER BY value ASC"),
           "completions are read in order — a truncated read must hold the first values")
    expect(query.sql.contains("IS NOT NULL"), "NULL is not something to complete a value to")
    expectEqual(query.params, [smallParquet.path], "with nothing typed there is nothing else to bind")

    let bounded = SQLBuilder.orderedDistinctValues(
        source: .file(smallParquet), column: labelColumn, startingAt: "row-5", limit: 10)
    expect(bounded.sql.contains(">= $2"), "typed text is bound, never interpolated")
    expectEqual(bounded.params, [smallParquet.path, "row-5"], "and bound after the path")
}

do {
    let probe = Probe(session: session)
    let label = ColumnInfo(name: "label", typeName: "VARCHAR")

    let index = try await probe.distinctValueIndex(for: label, in: .file(smallParquet))
    expect(index.isComplete, "a thousand values is well inside what an index holds")
    expectEqual(index.values.count, 1000, "every distinct value is held")
    expectEqual(index.suggestions(startingAt: "row-1"),
                ["row-1", "row-10", "row-100", "row-101", "row-102",
                 "row-103", "row-104", "row-105", "row-106", "row-107"],
                "completions come back lexicographic, which is the order the index is in")

    // Truncation. Holding the lexicographically *first* values rather than an
    // arbitrary set is what makes a truncated index usable at all: it is exact
    // as far as it goes, and the caller can tell where that ends.
    let clipped = try await probe.distinctValueIndex(for: label, in: .file(smallParquet), limit: 5)
    expect(!clipped.isComplete, "a column past the limit is known to be truncated")
    expectEqual(clipped.values, ["row-0", "row-1", "row-10", "row-100", "row-101"],
                "and what it holds is the first values, not whichever five came out of the hash table")

    // So only the stretch past the end of a truncated index has to reach DuckDB.
    let far = try await probe.valueSuggestions(
        for: label, in: .file(smallParquet), startingAt: "row-99")
    expectEqual(far, ["row-99", "row-990", "row-991", "row-992", "row-993",
                      "row-994", "row-995", "row-996", "row-997", "row-998"],
                "DuckDB answers for a stretch no index holds, in the same order")

    // NULLs are dropped rather than spending the limit. `is null` is the
    // operator that asks for them, and there is nothing to complete one to.
    let sparse = try await probe.distinctValueIndex(
        for: ColumnInfo(name: "maybe_text", typeName: "VARCHAR"), in: .file(typesParquet))
    expectEqual(sparse.values.count, 171, "the 29 NULL rows contribute no value to complete to")
    expect(!sparse.values.contains(""), "and none of them arrives as an empty string")
}

do {
    // End to end through the model, which is where the index gets cached.
    let completionCache = PreviewCache()
    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "complete-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "complete-meta"),
        countSession: try DuckDBSession(engine: engine, label: "complete-count"),
        filterSession: try DuckDBSession(engine: engine, label: "complete-filter"),
        cache: completionCache
    )
    model.open(.file(smallParquet))

    let label = ColumnInfo(name: "label", typeName: "VARCHAR")
    expectEqual(try await model.valueSuggestions(for: label, startingAt: "row-99"),
                ["row-99", "row-990", "row-991", "row-992", "row-993",
                 "row-994", "row-995", "row-996", "row-997", "row-998"],
                "the model completes from the column's real values")

    let fingerprint = SourceFingerprint.compute(for: .file(smallParquet))!
    expect(completionCache.valueIndex(for: fingerprint, column: "label") != nil,
           "the read is remembered, so the next keystroke is a binary search rather than a scan")

    // Fast typing must not mean a scan per keystroke: the reads in flight are
    // shared, so these all resolve to one index.
    async let a = model.valueSuggestions(for: label, startingAt: "row-2")
    async let b = model.valueSuggestions(for: label, startingAt: "row-20")
    async let c = model.valueSuggestions(for: label, startingAt: "row-200")
    expectEqual(try await a.first, "row-2", "each keystroke gets its own answer")
    expectEqual(try await b.first, "row-20", "…from the one shared index")
    expectEqual(try await c.first, "row-200", "…however fast they arrive")

    // In SQL mode there is no source to read a column's values from, and the
    // filter bar is disabled anyway.
    model.runSQL("SELECT 1 AS x")
    try? await Task.sleep(for: .milliseconds(200))
    expect(try await model.valueSuggestions(for: label, startingAt: "row").isEmpty,
           "a SQL result has no column values to complete against")
}

// MARK: - Preview cache

section("Preview cache")

do {
    let fingerprint = SourceFingerprint.compute(for: .file(smallParquet))
    expect(fingerprint != nil, "a real file can be fingerprinted")
    expectEqual(SourceFingerprint.compute(for: .file(smallParquet)), fingerprint,
                "an unchanged file fingerprints the same twice")
    expect(SourceFingerprint.compute(for: .file(fixtures.appendingPathComponent("nope.parquet"))) == nil,
           "a missing file has no fingerprint, so nothing can be served for it")

    let datasetPrint = SourceFingerprint.compute(for: .dataset(hiveDirectory))
    expect(datasetPrint != nil, "a dataset fingerprints from the files under it")
    expect((datasetPrint?.fileCount ?? 0) > 1, "the dataset fingerprint counts every file it found")
    expect(datasetPrint != fingerprint, "a dataset and a file do not share a fingerprint")

    // A rewritten file must not be served from the old entry. This is the whole
    // correctness question for the cache, so it is tested against a real write
    // rather than by trusting the key's fields.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-cache-\(UUID().uuidString).parquet")
    defer { try? FileManager.default.removeItem(at: scratch) }
    try await session.execute(
        "COPY (SELECT * FROM range(10) t(i)) TO '\(scratch.path)' (FORMAT parquet)")
    let firstPrint = SourceFingerprint.compute(for: .file(scratch))
    try await session.execute(
        "COPY (SELECT * FROM range(5000) t(i)) TO '\(scratch.path)' (FORMAT parquet)")
    let secondPrint = SourceFingerprint.compute(for: .file(scratch))
    expect(firstPrint != nil && secondPrint != nil, "both writes are fingerprintable")
    expect(firstPrint != secondPrint, "rewriting a file changes its fingerprint")

    // Storage behaviour.
    let cache = PreviewCache(capacity: 2)
    let preview = CachedPreview(columns: [scoreColumn], rows: [["1"]], totalRowCount: 1, reachedEnd: true)
    cache.store(preview, for: firstPrint!)
    expect(cache.preview(for: firstPrint!) != nil, "a stored preview comes back")
    expect(cache.preview(for: secondPrint!) == nil, "a different fingerprint is a miss")
    cache.store(preview, for: secondPrint!)
    cache.store(preview, for: datasetPrint!)
    expectEqual(cache.count, 2, "the cache stays at its capacity")

    // The inspector's answers are remembered against the same fingerprint. Its
    // per-column statistics come from parquet_metadata, which reads every
    // footer in the dataset — the most expensive question the app asks, and the
    // one most worth not asking twice.
    let statsCache = PreviewCache(capacity: 2)
    let summary = try await Probe(session: session).fileMetadata(of: .file(smallParquet))
    statsCache.storeStats(
        CachedStats(fileSummary: summary, columnStatistics: nil, keyValues: nil),
        for: firstPrint!)
    expect(statsCache.stats(for: firstPrint!) != nil, "stored stats come back")
    expectEqual(statsCache.stats(for: firstPrint!)?.fileSummary?.value(row: 0, named: "files"), "1",
                "and they are the same answer, not a placeholder")
    expect(statsCache.stats(for: secondPrint!) == nil, "a changed file is a miss for stats too")
    statsCache.clear()
    expect(statsCache.stats(for: firstPrint!) == nil, "clearing drops stats as well as previews")

    // One recency order governs both stores, so a source cannot linger in one
    // after being evicted from the other.
    let shared = PreviewCache(capacity: 1)
    shared.store(preview, for: firstPrint!)
    shared.storeStats(CachedStats(fileSummary: summary, columnStatistics: nil, keyValues: nil),
                      for: firstPrint!)
    shared.store(preview, for: secondPrint!)
    expect(shared.preview(for: firstPrint!) == nil, "the evicted source loses its preview")
    expect(shared.stats(for: firstPrint!) == nil, "and its stats go with it")

    cache.clear()
    expectEqual(cache.count, 0, "clearing empties it")
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
    // Its own cache, so these assertions describe this model rather than
    // whatever an earlier section happened to leave in the shared one.
    let modelCache = PreviewCache()
    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "model-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "model-meta"),
        countSession: try DuckDBSession(engine: engine, label: "model-count"),
        filterSession: try DuckDBSession(engine: engine, label: "model-filter"),
        cache: modelCache
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

    expectEqual(model.windowSize, TableModel.pageSize, "the query is bounded to the opening window")

    // Scrolling widens the window and re-runs, rather than reading further
    // along an open stream.
    model.loadMoreIfNeeded(displayedIndex: model.rows.count - 1)
    await settle(model)
    expectEqual(model.windowSize, TableModel.pageSize * 2, "scrolling doubles the window")
    expectEqual(model.rows.count, 1000, "scrolling to the end loads the rest of the file")
    expect(model.reachedEnd, "fewer rows than the window asked for means the result is exhausted")

    // Row ids must stay contiguous, since the grid keys on them.
    expectEqual(model.rows.map(\.id), Array(0..<1000), "row ids stay contiguous across a widening")

    // Three-state sort cycling, each step a fresh DuckDB query.
    let idIndex = model.columns.firstIndex { $0.name == "id" }!
    func firstID() -> String? { model.rows.first?.cells[idIndex] }

    expectEqual(firstID(), "0", "unsorted starts at the file's first row")

    // Re-sorting must not blank the grid while the new query runs. The rows on
    // screen are the same rows in a different order, so clearing them says
    // something untrue about the data for as long as the sort takes — which is
    // what the flicker was.
    let rowsBeforeSort = model.rows.count
    model.toggleSort(column: "id")
    expectEqual(model.rows.count, rowsBeforeSort, "a sort keeps the current rows until new ones arrive")
    expectEqual(model.sortDirection(for: "id"), .ascending,
                "the header shows the new sort immediately, so nothing is misrepresented")
    await settle(model)
    expectEqual(model.sortDirection(for: "id"), .ascending, "first click sorts ascending")
    expectEqual(model.rows.count, TableModel.pageSize,
                "the first page of the new sort replaces the old rows outright")
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

    // Right-clicking a cell filters by the value in it.
    model.filter(column: categoryColumn, matching: "alpha")
    await settle(model)
    expectEqual(model.totalRowCount, 250, "filtering by a cell's value reaches DuckDB")
    expectEqual(model.filters.count, 1, "one filter, on the column that was clicked")

    // A second value on the same column widens the selection rather than
    // stacking a second filter that no row could satisfy — two ANDed equality
    // filters on one column always match nothing.
    model.filter(column: categoryColumn, matching: "beta")
    await settle(model)
    expectEqual(model.filters.count, 1, "a second value joins the existing filter")
    expectEqual(model.totalRowCount, 500, "and widens it rather than contradicting it")

    // NULL is a value to filter by, not the absence of one.
    let sparseColumn = ColumnInfo(name: "flag", typeName: "VARCHAR")
    let nullFilter = TableModel(
        gridSession: session, metaSession: session, countSession: session,
        filterSession: session, cache: PreviewCache()
    )
    nullFilter.filter(column: sparseColumn, matching: nil)
    if case .anyOf(let values, let includeNull) = nullFilter.filters[0].mode {
        expect(values.isEmpty, "a NULL cell contributes no literal value")
        expect(includeNull, "it asks for NULL rows")
    } else {
        expect(false, "filtering a cell always produces a value filter")
    }

    model.clearFilters()
    await settle(model)

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

    // EXPLAIN, end to end. It is the one read-only statement that can be
    // neither windowed nor rendered as text, since both are a SELECT over it —
    // so this checks the exemption reaches all the way through to the grid.
    model.runSQL("EXPLAIN SELECT 1 AS a")
    await settle(model)
    expectEqual(model.errorMessage, String?.none, "EXPLAIN runs in the editor rather than failing to parse")
    expect(model.rows.count > 0, "EXPLAIN returns its plan")

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

    // Timing. Every completed load leaves a duration behind and stops the
    // running clock, which is what the status bar switches between.
    expect(model.lastQueryDuration != nil, "a finished load records how long it took")
    expect(model.queryStartedAt == nil, "the running clock stops when the load finishes")

    // Cancelling. The state machine is the part that can be wrong on a small
    // file — the interrupt itself is exercised against the 10M-row fixture.
    model.reload()
    expect(model.isBusy, "a reload is immediately busy, so there is something to cancel")
    model.cancel()
    expect(!model.isBusy, "cancelling stops reporting work in progress")
    expect(model.wasCancelled, "the status bar can say the load was stopped, not that it failed")
    expectEqual(model.errorMessage, String?.none, "cancelling is not an error")

    model.open(.file(smallParquet))
    await settle(model)
    expect(!model.wasCancelled, "the next load clears the cancelled state")

    // Second open of an unchanged file comes from memory. Scrolling past the
    // remembered window still has to work, which means reading for real at that
    // point.
    model.clear()
    model.open(.file(smallParquet))
    await settle(model)
    expect(model.servedFromCache, "re-opening an unchanged file is served from the cache")
    expectEqual(model.rows.count, TableModel.pageSize, "the cached page is a page, not the file")
    expectEqual(model.totalRowCount, 1000, "the row count is remembered alongside the rows")
    expectEqual(model.columns.count, 6, "the schema is remembered too")

    model.loadMore()
    await settle(model)
    expectEqual(model.rows.count, 1000, "scrolling past the cached window reads the rest for real")
    expectEqual(model.rows.map(\.id), Array(0..<1000), "ids stay contiguous across the cache boundary")
    // The rows past the cached ones must be the file's actual next rows, which
    // contiguous ids alone would not catch.
    expectEqual(model.rows[500].cells[idIndex], "500",
                "the widened window continues past the cached rows rather than repeating them")

    modelCache.clear()
    model.clear()
    model.open(.file(smallParquet))
    await settle(model)
    expect(!model.servedFromCache, "clearing the cache forces a fresh read")
    expectEqual(model.rows.count, TableModel.pageSize, "and the fresh read still works")
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
        metaSession: try DuckDBSession(engine: engine, label: "big-meta"),
        countSession: try DuckDBSession(engine: engine, label: "big-count"),
        filterSession: try DuckDBSession(engine: engine, label: "big-filter")
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

    expectEqual(model.windowSize, TableModel.pageSize, "the opening window is one page")

    // Widening doubles, so reaching depth costs a bounded number of re-runs
    // rather than one per 500 rows.
    let pageAt = Date()
    for _ in 0..<4 {
        model.loadMore()
        await settle(model)
    }
    let pageElapsed = Date().timeIntervalSince(pageAt)
    expectEqual(model.windowSize, TableModel.pageSize * 16, "four widenings double the window each time")
    expectEqual(model.rows.count, TableModel.pageSize * 16, "and the grid holds the whole widened window")
    expect(pageElapsed < 10, "widening stays cheap (4 steps in \(String(format: "%.2f", pageElapsed))s)")
    print("  4 widenings to \(model.windowSize) rows: \(String(format: "%.2f", pageElapsed))s")

    // Sorting 10M rows is a real sort; it must be pushed down and correct.
    // With the window in place it is a Top-N, so the elapsed time here is the
    // number the LIMIT exists to hold down.
    model.reload()
    await settle(model)
    let sortAt = Date()
    model.toggleSort(column: "measure")
    await settle(model)
    let sortElapsed = Date().timeIntervalSince(sortAt)
    expectEqual(model.windowSize, TableModel.pageSize, "sorting starts from the opening window again")
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

    // The Cancel button, against a query long enough for the word to mean
    // something. It must stop promptly rather than waiting for a 10M-row sort
    // to finish into a result nobody asked for.
    model.clearSort()
    await settle(model)
    let stopAt = Date()
    model.toggleSort(column: "key")
    model.cancel()
    let stopElapsed = Date().timeIntervalSince(stopAt)
    expect(!model.isBusy, "cancelling a 10M-row sort returns immediately")
    expect(model.wasCancelled, "and says it was stopped rather than that it failed")
    expect(stopElapsed < 1, "cancel does not block on the running query (took \(String(format: "%.2f", stopElapsed))s)")
    expectEqual(model.errorMessage, String?.none, "an interrupted query is not reported as an error")

    // And the model still works afterwards.
    model.reload()
    await settle(model)
    expectEqual(model.rows.count, TableModel.pageSize, "the grid recovers after a cancel")
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
