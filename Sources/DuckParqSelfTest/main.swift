import AppKit
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

/// Enough of a data source for a table view to have three rows to be clicked on
/// or missed — see the sidebar hit tests.
@MainActor
final class ThreeRows: NSObject, NSTableViewDataSource {
    static let shared = ThreeRows()

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // DuckParqSelfTest
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // package root
let fixtures = packageRoot.appendingPathComponent(".fixtures")
let smallParquet = fixtures.appendingPathComponent("small.parquet")
let typesParquet = fixtures.appendingPathComponent("types.parquet")
let hiveDirectory = fixtures.appendingPathComponent("hive")
let uniformDirectory = fixtures.appendingPathComponent("uniform")
let mixedDirectory = fixtures.appendingPathComponent("mixed")
let reorderedDirectory = fixtures.appendingPathComponent("reordered")
let corruptParquet = fixtures.appendingPathComponent("corrupt.parquet")

guard FileManager.default.fileExists(atPath: smallParquet.path),
      FileManager.default.fileExists(atPath: mixedDirectory.path)
else {
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
    let listing = await FileTree.listing(of: fixtures)
    expectEqual(listing.outcome, .ok, "a readable directory lists successfully")
    expect(listing.nodes.contains { $0.name == "small.parquet" }, "parquet files are listed")
    expect(listing.nodes.contains { $0.name == "hive" && $0.isDataset },
           "a hive directory is flagged as a dataset")
    expect(listing.nodes.contains { $0.name == "uniform" && $0.isDataset },
           "so is a folder whose files agree on a schema")
    expect(listing.nodes.contains { $0.name == "mixed" && !$0.isDataset },
           "a folder whose files disagree is listed as a folder")
    expect(!listing.nodes.contains { $0.name.hasSuffix(".ips") }, "non-parquet files are hidden")

    // The listing is what carries the answer; a bare directory walk does not
    // pay for it, because the tree walks behind Expand All and the filter field
    // would otherwise probe every folder they pass.
    expect(FileTree.children(of: fixtures).allSatisfy { !$0.isDataset },
           "a plain directory walk classifies nothing")

    // Directories sort before files, so the tree reads top-down.
    let firstFileIndex = listing.nodes.firstIndex { !$0.isDirectory } ?? listing.nodes.count
    expect(listing.nodes.prefix(firstFileIndex).allSatisfy(\.isDirectory),
           "directories are listed before files")

    // An unreadable directory must be distinguishable from an empty one —
    // otherwise the sidebar silently shows "no parquet files" when the real
    // problem is that macOS refused access.
    let missing = await FileTree.listing(of: fixtures.appendingPathComponent("does-not-exist"))
    expect(missing.outcome != .ok, "an unreadable directory reports why, not just an empty list")
    expect(missing.nodes.isEmpty, "a failed listing yields no nodes")

    // A hive layout is one table whose partitions are columns. Listing
    // `year=2024/` as a folder invites opening a slice of a dataset as though
    // it were a thing in its own right, so the partitions are withheld and the
    // folder is offered whole.
    let hiveListing = await FileTree.listing(of: hiveDirectory)
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

    // The outermost partition key names the column the dataset is laid out by,
    // which is the one it opens ordered by.
    expectEqual(FileTree.topLevelHiveKey(of: hiveDirectory), "year",
                "the top-level partition key is read from the partition folder names")
    expectEqual(FileTree.topLevelHiveKey(of: fixtures), String?.none,
                "a plain folder of parquet files has no partition key")
    expectEqual(FileTree.topLevelHiveKey(of: hiveDirectory.appendingPathComponent("nope")),
                String?.none, "an unreadable directory has no partition key")

    // Search must not descend into partitions either, or a hive dataset floods
    // the results with a file per partition.
    expect(await FileTree.search(root: hiveDirectory, query: "data").isEmpty,
           "search does not reach into hive partitions")

    // A folder that matched by name is only a result if it is something the
    // sidebar can open — there is nothing to do with a row for a plain folder.
    let found = await FileTree.search(root: fixtures, query: "iform")
    expectEqual(found.map(\.name), ["uniform"], "a matching dataset folder is a search result")
    expect(found.allSatisfy(\.isDataset), "and comes back classified, unlike a bare walk")
    expect(await FileTree.search(root: fixtures, query: "mixed").isEmpty,
           "a matching folder that is not a dataset is not offered")

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

// MARK: - Folder or dataset
//
// A folder is a dataset when it is hive-partitioned, or when one glob covers
// its files without `union_by_name = true`. The second half is not a question
// about names on disk, so it is put to DuckDB rather than guessed at — which
// means these check the answers the reader actually gives, including where they
// are more generous than "the schemas are identical" would be.

section("Folder or dataset")

do {
    expect(await FileTree.looksLikeDataset(hiveDirectory),
           "a hive-partitioned folder reads as a dataset, from its names alone")
    expect(await FileTree.looksLikeDataset(uniformDirectory),
           "so does a folder whose files agree on a schema")

    // The rule that changed: holding parquet files is no longer enough. The
    // fixtures directory holds three files with nothing in common, and a glob
    // over it needs union_by_name — so it is a folder to browse.
    expect(!(await FileTree.looksLikeDataset(fixtures)),
           "a folder of unrelated parquet files is a folder, not a dataset")
    expect(!(await FileTree.looksLikeDataset(mixedDirectory)),
           "two files that disagree on their columns make a folder")

    // Not "byte-identical schemas": the question is what the reader will accept,
    // and DuckDB matches a glob's columns by name. Files that list the same
    // columns in a different order glob fine, so they are one dataset.
    expect(await FileTree.looksLikeDataset(reorderedDirectory),
           "columns in a different order still glob, so the folder is a dataset")

    // Nothing to be uniform about is not uniformity, and neither is a folder
    // that cannot be read at all.
    let empty = fixtures.appendingPathComponent("empty-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    expect(!(await FileTree.looksLikeDataset(empty)), "an empty folder is not a dataset")
    expect(!(await FileTree.looksLikeDataset(fixtures.appendingPathComponent("nope"))),
           "nor is a folder that does not exist")

    // A folder of folders has no files of its own to agree about. Browsing into
    // it is the whole point of it, so it must not be badged as one table.
    let nested = fixtures.appendingPathComponent("nested-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: nested.appendingPathComponent("inner"), withIntermediateDirectories: true)
    try? FileManager.default.copyItem(
        at: smallParquet, to: nested.appendingPathComponent("inner/small.parquet"))
    defer { try? FileManager.default.removeItem(at: nested) }
    expect(!(await FileTree.looksLikeDataset(nested)),
           "a folder whose parquet files are all further down stays a folder")

    // A file DuckDB cannot read leaves the question unanswered, and an
    // unanswered question is not a dataset — the badge says the folder opens as
    // one table, so it may only appear once that has been shown.
    let broken = fixtures.appendingPathComponent("broken-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: smallParquet, to: broken.appendingPathComponent("a.parquet"))
    try? FileManager.default.copyItem(at: corruptParquet, to: broken.appendingPathComponent("b.parquet"))
    defer { try? FileManager.default.removeItem(at: broken) }
    expect(!(await FileTree.looksLikeDataset(broken)),
           "a folder holding a file that will not read is not a dataset")

    // The probe reads no rows: `file_row_number` is generated by the reader and
    // starts at zero, so the filter drops every row group before a page is
    // touched. That is what makes it affordable to ask per folder.
    let probe = SQLBuilder.schemaAgreement(under: uniformDirectory)
    expect(probe.sql.contains("file_row_number = true"), "the probe asks for the generated column")
    expect(probe.sql.contains("< 0"), "and filters it to nothing, so no data page is read")
    expect(!probe.sql.contains("union_by_name"),
           "and never with union_by_name, which is the option that would hide a mismatch")
    expectEqual(probe.params, [DataSource.dataset(uniformDirectory).readPath],
                "over the same glob opening the folder would use")
}

do {
    // A folder whose files already have a column called `file_row_number`
    // cannot be read with the option on at all. That refusal says nothing about
    // whether the schemas agree, so it must not be mistaken for a mismatch.
    let collides = fixtures.appendingPathComponent("collides-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: collides, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: collides) }

    let session = try DuckDBSession(engine: .shared, label: "test-collides")
    for (name, start) in [("a", 0), ("b", 50)] {
        let write = """
            COPY (SELECT i AS file_row_number, 'row-' || i AS label \
            FROM range(\(start), \(start + 50)) t(i)) \
            TO '\(collides.appendingPathComponent("\(name).parquet").path)' (FORMAT parquet)
            """
        try await session.execute(write)
    }

    expect(await FileTree.looksLikeDataset(collides),
           "a folder of files with their own file_row_number column is still a dataset")

    // And it is the refusal itself that has to say so, not merely the answer:
    // the fallback probe is only reached by classifying this error, so ask
    // DuckDB for it and put the real text to the test.
    let probe = SQLBuilder.schemaAgreement(under: collides)
    do {
        _ = try await session.queryAll(probe.sql, params: probe.params, limit: 1)
        expect(false, "the probe must refuse a folder it cannot use the option on")
    } catch let error as DuckDBError {
        expect(error.isRowNumberCollision,
               "the refusal for the option's own name is read as a collision")
    }
}

do {
    // The other half, and the one a name test gets wrong: an ordinary schema
    // mismatch lists the columns the read could have bound to, and the probe's
    // own generated column is among them —
    //
    //     Candidate names: id, amount, file_row_number
    //
    // so a message merely mentioning `file_row_number` proves nothing. Read as
    // a collision it would send every non-dataset folder through the slow
    // fallback, which the sidebar pays for on each folder it draws.
    let mismatch = fixtures.appendingPathComponent("mismatch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: mismatch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mismatch) }

    let session = try DuckDBSession(engine: .shared, label: "test-mismatch")
    let files = [
        ("part-0", "SELECT i AS id, i * 2 AS amount, 'row-' || i AS label FROM range(0, 50) t(i)"),
        ("priced", "SELECT i AS id, i * 2 AS amount FROM range(0, 50) t(i)"),
    ]
    for (name, select) in files {
        let path = mismatch.appendingPathComponent("\(name).parquet").path
        try await session.execute("COPY (\(select)) TO '\(path)' (FORMAT parquet)")
    }

    let probe = SQLBuilder.schemaAgreement(under: mismatch)
    do {
        _ = try await session.queryAll(probe.sql, params: probe.params, limit: 1)
        expect(false, "files that disagree on their columns must fail the probe")
    } catch let error as DuckDBError {
        expect(!error.isRowNumberCollision,
               "a mismatch naming the generated column among its candidates is still a mismatch")
        expect(error.localizedDescription.contains(DataSource.rowNumberColumn),
               "and it does name it, which is why the name alone cannot decide this")
    }

    expect(!(await FileTree.looksLikeDataset(mismatch)),
           "so the folder is answered from the first probe, and is not a dataset")
}

// MARK: - Expanding into an only child
//
// A folder holding one folder, holding one folder, is a row whose only use is
// to be clicked. Expanding the first opens the whole run of them, and where it
// stops is the whole of the rule — see `FileTree.unbranchedDescent`.

section("Expanding into an only child")

do {
    let base = fixtures.appendingPathComponent("descent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func folder(_ path: String) -> URL {
        let url = base.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func parquet(_ path: String) {
        try? FileManager.default.copyItem(at: smallParquet, to: base.appendingPathComponent(path))
    }

    // The tree the rule exists for: four folders deep before anything can be
    // opened, and a dataset at the bottom of it.
    let unbranched = folder("unbranched")
    folder("unbranched/cc-index/table/cc-main/warc")
    parquet("unbranched/cc-index/table/cc-main/warc/a.parquet")
    parquet("unbranched/cc-index/table/cc-main/warc/b.parquet")
    // Rows are counted as the sidebar draws them, and it draws neither hidden
    // files nor ones it cannot open — so neither stops the walk.
    try? "notes".write(to: unbranched.appendingPathComponent("README.md"),
                       atomically: true, encoding: .utf8)

    expectEqual(await FileTree.unbranchedDescent(from: unbranched).map(\.lastPathComponent),
                ["cc-index", "table", "cc-main"],
                "expanding a folder opens the run of only-children below it")
    expect(await FileTree.looksLikeDataset(
        unbranched.appendingPathComponent("cc-index/table/cc-main/warc")),
           "and stops on a dataset, which is a table to read rather than a level to pass through")
    expect(!(await FileTree.unbranchedDescent(from: unbranched).contains(unbranched)),
           "the folder that was expanded is not in its own descent")

    // Two rows is something to choose between, and the choice is the reader's.
    let branch = folder("branch")
    folder("branch/left")
    folder("branch/right")
    expect(await FileTree.unbranchedDescent(from: branch).isEmpty,
           "a folder that branches opens no further")

    // The one row is a file: there is nothing below it to open.
    let singleFile = folder("single-file")
    parquet("single-file/small.parquet")
    expect(await FileTree.unbranchedDescent(from: singleFile).isEmpty,
           "and neither does a folder whose one row is a file")

    // It stops *at* the branch, not one short of it: the folder that leads there
    // is still a row worth clicking through on the reader's behalf.
    let oneThenTwo = folder("one-then-two")
    folder("one-then-two/only/x")
    folder("one-then-two/only/y")
    expectEqual(await FileTree.unbranchedDescent(from: oneThenTwo).map(\.lastPathComponent),
                ["only"],
                "the pass-through folder is opened, the branching folder inside it is not")

    // A hive layout is a dataset from its names alone, and is left shut for the
    // same reason: its partitions are columns of one table, not folders.
    let hiveChain = folder("hive-chain")
    folder("hive-chain/one/partitioned/year=2024")
    parquet("hive-chain/one/partitioned/year=2024/data.parquet")
    expectEqual(await FileTree.unbranchedDescent(from: hiveChain).map(\.lastPathComponent),
                ["one"],
                "a hive dataset ends the descent, one row below the folder that was expanded")

    // Bounded, because a symlink pointing back up its own chain is a run of
    // only-children that never ends.
    let deep = folder("deep")
    folder("deep/a/b/c/d/e")
    expectEqual(await FileTree.unbranchedDescent(from: deep).map(\.lastPathComponent),
                ["a", "b", "c", "d", "e"], "a long run is followed to the end of it")
    expectEqual(await FileTree.unbranchedDescent(from: deep, limit: 2).map(\.lastPathComponent),
                ["a", "b"], "but never past the limit")

    expect(await FileTree.unbranchedDescent(from: folder("empty")).isEmpty,
           "an empty folder opens nothing further")
    expect(await FileTree.unbranchedDescent(from: base.appendingPathComponent("gone")).isEmpty,
           "nor does a folder that is not there")
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

// MARK: - Remembering which folders are open
//
// The sidebar's open folders outlive the session, so the set has to survive a
// round trip through defaults — and come back pruned of everything a restarted
// app can no longer draw.

section("Sidebar expansion")

do {
    // A tree on disk, because what may be restored is decided by what is still
    // there: hive/ and uniform/ are datasets, and both expand like any folder.
    let root = fixtures
    let hive = root.appendingPathComponent("hive")
    let uniform = root.appendingPathComponent("uniform")

    let saved = SidebarExpansion.encoded([root, hive, uniform])
    expectEqual(Set(saved), Set([root.path, hive.path, uniform.path]),
                "the open folders are saved as plain paths")
    expectEqual(SidebarExpansion.decoded(saved, under: [root]), Set([root, hive, uniform]),
                "and come back as the same folders, datasets included")

    // The saved list is written on every toggle, so it has to be stable —
    // otherwise identical state churns defaults on each keystroke of the tree.
    expectEqual(SidebarExpansion.encoded([uniform, root, hive]), saved,
                "the same set always saves in the same order")

    // Everything below is a reason an entry cannot be drawn any more, and so
    // has no business being restored.
    expect(!SidebarExpansion.decoded([root.appendingPathComponent("gone").path], under: [root])
        .contains(root.appendingPathComponent("gone")),
           "a folder deleted since the last launch is not restored")
    expect(SidebarExpansion.decoded([smallParquet.path], under: [root]).isEmpty,
           "nor is a path that is now a file")
    expect(SidebarExpansion.decoded([hive.path], under: [uniform]).isEmpty,
           "nor one under no added folder — the row has nowhere to be")
    expect(SidebarExpansion.decoded([hive.path], under: []).isEmpty,
           "with every folder removed, nothing is left open")

    // An added folder reached by a spelling of its own: the sidebar's rows are
    // built by appending onto the root as the user chose it, so a restored URL
    // that spells the same folder differently matches no row at all.
    let slashed = URL(fileURLWithPath: root.path, isDirectory: true)
    let restored = SidebarExpansion.decoded([hive.path], under: [slashed])
    expectEqual(restored, Set([slashed.appendingPathComponent("hive")]),
                "a restored folder is respelled onto the added folder holding it")
    expect(restored.first.map { FileTree.children(of: slashed).map(\.url).contains($0) } == true,
           "and so equals the URL the directory listing produces")

    // Two saved spellings of one folder are one folder, so the cap counts rows
    // rather than strings.
    expectEqual(SidebarExpansion.decoded([hive.path, hive.path + "/"], under: [root]).count, 1,
                "one folder saved twice is restored once")

    // Expand All opens thousands at once; defaults should not grow without
    // bound for a state whose whole job is to look like where you left off.
    let many = (0..<(SidebarExpansion.limit + 500)).map { root.appendingPathComponent("d\($0)") }
    let capped = SidebarExpansion.encoded(Set(many).union([root]))
    expectEqual(capped.count, SidebarExpansion.limit, "the saved list is capped")
    expectEqual(capped.first, root.path,
                "and keeps the shallowest folders — the top of the tree is what is on screen")
}

// MARK: - Watching the added folders
//
// A folder in the sidebar is a view of a directory, not a photograph of it. The
// three pieces of that are checked here: putting a path the system reported back
// into the spelling the sidebar's rows are built from, the stream that reports
// them, and the rows being re-read when one arrives.

section("Folder watching")

do {
    let data = URL(fileURLWithPath: "/data")

    expectEqual(FileTree.chain(to: URL(fileURLWithPath: "/data/2024/q1"), under: data)?.map(\.path) ?? [],
                ["/data", "/data/2024", "/data/2024/q1"],
                "the chain to a folder ends on the folder itself, unlike ancestors()")
    expectEqual(FileTree.chain(to: data, under: data)?.map(\.path) ?? [],
                ["/data"], "an added folder is its own chain")
    expect(FileTree.chain(to: URL(fileURLWithPath: "/database/x"), under: data) == nil,
           "a folder is not matched by a name it merely starts")

    // The case the whole respelling exists for: FSEvents answers in resolved
    // paths, and the roots are spelled however they were added.
    expectEqual(FileTree.chain(to: URL(fileURLWithPath: "/private/tmp/sales"),
                               under: URL(fileURLWithPath: "/tmp"))?.map(\.path) ?? [],
                ["/tmp", "/tmp/sales"],
                "a change reported through a symlinked root comes back in the root's spelling")

    let roots = [data, URL(fileURLWithPath: "/data/2024")]
    expectEqual(FileTree.chain(to: URL(fileURLWithPath: "/data/2024/q1"), in: roots)?.first?.path,
                "/data/2024", "the deepest added folder is the one a change is rebased onto")
    expect(FileTree.chain(to: URL(fileURLWithPath: "/elsewhere/x"), in: roots) == nil,
           "a change outside every added folder belongs to none of them")

    expect(FileTree.isSameDirectory(URL(fileURLWithPath: "/data", isDirectory: true), data),
           "a trailing slash does not make it a different folder")
    expect(FileTree.isSameDirectory(URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: "/tmp")),
           "nor does a symlink in the path")
    expect(!FileTree.isSameDirectory(data, URL(fileURLWithPath: "/data/2024")),
           "a folder is not the same as one inside it")
}

/// Collects what a watcher reports, which arrives on a queue of its own.
actor WatchLog {
    private var changes: [DirectoryWatcher.Change] = []

    func add(_ reported: [DirectoryWatcher.Change]) { changes += reported }

    /// Wait for a change naming `directory` or something under it.
    func sawChange(under directory: URL, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if changes.contains(where: { FileTree.chain(to: $0.url, under: directory) != nil }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

do {
    // Deliberately under the temporary directory rather than the fixtures: it
    // is reached through /var, which the system reports as /private/var, so the
    // stream exercises the respelling above rather than sidestepping it.
    let watched = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckparq-watch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: watched) }

    let log = WatchLog()
    let watcher = DirectoryWatcher(latency: 0.05) { changes in
        Task { await log.add(changes) }
    }
    watcher.watch([watched])
    expect(watcher.isWatching, "a watcher over an added folder has a stream running")

    // Watching nothing is not an error, and must not leave a stream behind.
    let idle = DirectoryWatcher { _ in }
    idle.watch([])
    expect(!idle.isWatching, "watching no folders starts no stream")

    // The stream is created for events from now on, so a change made in the
    // same breath as starting it has nothing to be attributed to.
    try? await Task.sleep(for: .milliseconds(300))
    try? FileManager.default.copyItem(at: smallParquet, to: watched.appendingPathComponent("a.parquet"))

    expect(await log.sawChange(under: watched),
           "a file appearing in a watched folder is reported")

    watcher.stop()
    expect(!watcher.isWatching, "and stopping takes the stream down")
}

/// Wait for a folder to have been read at least this many times.
@MainActor
func settleListing(_ listing: DirectoryListing, reads: Int, timeout: TimeInterval = 20) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if listing.reads >= reads { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return false
}

do {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckparq-listings-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.copyItem(
        at: uniformDirectory.appendingPathComponent("part-0.parquet"),
        to: root.appendingPathComponent("part-0.parquet"))

    let listings = DirectoryListings()
    let listing = listings.listing(for: root)
    expect(!listing.isLoaded, "a folder nothing has looked at has not been read")
    expect(!listings.isLoaded(root), "and the store says so without asking for a read")

    await listing.load()
    expectEqual(listing.nodes.map(\.name), ["part-0.parquet"], "the folder's one file is listed")
    expect(listing.isDataset, "a folder of one parquet file reads as one table")
    expect(listings.isLoaded(root), "and the store knows it has been read")

    // Rows are shared, not copied: a change has one place to land, whichever
    // row asks for the folder.
    expect(listings.listing(for: root) === listing, "asking twice yields the same folder")
    expect(listings.listing(for: URL(fileURLWithPath: root.path, isDirectory: true)) === listing,
           "and a trailing slash is not a different folder")

    // What the watcher reports when a file lands: the folder, named by the
    // resolved path, with no idea what changed inside it.
    try? FileManager.default.copyItem(
        at: mixedDirectory.appendingPathComponent("priced.parquet"),
        to: root.appendingPathComponent("priced.parquet"))
    listings.directoriesDidChange(
        [DirectoryWatcher.Change(url: root.resolvingSymlinksInPath())], in: [root])

    expect(await settleListing(listing, reads: 2), "the change starts a re-read")
    expectEqual(listing.nodes.map(\.name).sorted(), ["part-0.parquet", "priced.parquet"],
                "the file that appeared is in the rows, with nothing having asked for it")
    expect(!listing.isDataset,
           "and the folder stops being one table, so the remembered answer was forgotten too")

    listings.forget(under: root)
    expectEqual(listings.count, 0, "removing an added folder forgets what was read under it")
}

do {
    // A folder is classified by globbing it *recursively*, so a file several
    // levels down decides whether an added folder is one table. A change deep in
    // the tree therefore has to re-read every folder above it, not just the one
    // it happened in.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckparq-deep-\(UUID().uuidString)")
    let sub = root.appendingPathComponent("sub")
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.copyItem(
        at: uniformDirectory.appendingPathComponent("part-0.parquet"),
        to: root.appendingPathComponent("part-0.parquet"))

    let listings = DirectoryListings()
    let listing = listings.listing(for: root)
    let subListing = listings.listing(for: sub)
    await listing.load()
    await subListing.load()
    expect(listing.isDataset, "the folder reads as one table while nothing disagrees with it")

    try? FileManager.default.copyItem(
        at: mixedDirectory.appendingPathComponent("priced.parquet"),
        to: sub.appendingPathComponent("priced.parquet"))
    listings.directoriesDidChange(
        [DirectoryWatcher.Change(url: sub.resolvingSymlinksInPath())], in: [root])

    expect(await settleListing(listing, reads: 2), "a change below an added folder re-reads it too")
    expect(!listing.isDataset,
           "a file that disagrees, two levels down, takes the added folder's badge away")

    // A dropped-events flag says the kernel stopped queueing them, so nothing
    // under the path can be assumed to be current either.
    let subReads = subListing.reads
    listings.directoriesDidChange(
        [DirectoryWatcher.Change(url: root.resolvingSymlinksInPath(), includesSubdirectories: true)],
        in: [root])
    expect(await settleListing(subListing, reads: subReads + 1),
           "a change covering a subtree re-reads the folders below it as well")

    // A folder named by nothing that was added has no rows to correct.
    let before = listing.reads
    listings.directoriesDidChange(
        [DirectoryWatcher.Change(url: URL(fileURLWithPath: "/elsewhere"))], in: [root])
    try? await Task.sleep(for: .milliseconds(200))
    expectEqual(listing.reads, before, "a change outside every added folder re-reads nothing")
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

// Where DuckDB spills. Left alone, an in-memory database writes to `.tmp`
// *relative to the working directory* — which for a bundle launched from the
// Finder is `/`, so the first query big enough to spill died with
// `Failed to create directory ".tmp": Read-only file system`. The suite never
// saw it because a test process runs in the package directory, which is
// writable; hence a check on the setting rather than on a spill.
do {
    let configured = try await session.queryAll("SELECT current_setting('temp_directory') AS path")
    let path = configured.value(row: 0, named: "path") ?? ""
    expectEqual(path, engine.temporaryDirectory.path, "the engine points spills at a path of its own")
    expect(path.hasPrefix("/"), "which is absolute, so it does not depend on where the app was started")
    var isDirectory: ObjCBool = false
    expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue,
           "and exists by the time a query could need it")

    // It is a global setting, so a session opened afterwards inherits it —
    // which is what makes one SET at startup enough for all five sessions.
    let later = try DuckDBSession(engine: engine, label: "selftest-temp")
    let inherited = try await later.queryAll("SELECT current_setting('temp_directory') AS path")
    expectEqual(inherited.value(row: 0, named: "path"), path, "as does every session opened later")
}

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

    // What the schema panel adds to those columns: which of them are keys, in
    // what order, and how far each divides the dataset. The fixture is
    // year=2023,2024 over region=us,eu,apac, so six partitions of one file.
    let summary = try await probe.hiveSummary(of: dataset)
    expectEqual(summary?.keys.map(\.name), ["year", "region"],
                "the partition keys come back in hierarchy order")
    expectEqual(summary?.keys.map(\.distinctValues), [2, 3],
                "with the distinct values each key takes")
    expectEqual(summary?.partitionCount, 6, "and the number of partitions on disk")

    // Only a hive layout has one. A single file is not a dataset at all, and a
    // folder of plain parquet files is one table without being partitioned.
    expectEqual(try await probe.hiveSummary(of: .file(smallParquet)), HiveSummary?.none,
                "a single file has no hive schema")
    expectEqual(try await probe.hiveSummary(of: .dataset(uniformDirectory)), HiveSummary?.none,
                "nor does a folder of files that merely agree on a schema")
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

// MARK: - Parquet layout: hive partitioning and a write ordering

// A parquet export can be asked to split itself into `key=value` folders. The
// promise is that the split is only a layout: the same rows come back, with the
// partition columns restored from the paths they were moved into.
do {
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-hive")
    try? FileManager.default.removeItem(at: destination)

    let query = SQLBuilder.rows(source: .file(smallParquet))
    let layout = SQLBuilder.ParquetLayout(partitionBy: ["category", "flagged"])
    expect(SQLBuilder.writesDirectory(format: .parquet, layout: layout),
           "a partitioned export writes a folder, so the save panel offers one")
    expect(!SQLBuilder.writesDirectory(format: .csv, layout: layout),
           "the layout means nothing for CSV, which still writes one file")

    let copy = SQLBuilder.export(query: query, to: destination, format: .parquet, layout: layout)
    expect(copy.sql.contains("PARTITION_BY (\"category\", \"flagged\")"),
           "the keys are quoted identifiers in the order they were chosen")
    try await session.execute(copy.sql, params: copy.params)

    let directories = try FileManager.default
        .contentsOfDirectory(atPath: destination.path).sorted()
    expectEqual(directories, ["category=alpha", "category=beta", "category=delta", "category=gamma"],
                "the first key is the outermost folder level")
    expect(FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("category=alpha/flagged=true").path),
           "and the second nests inside it")

    // The columns are *moved*, not copied: they are gone from the files, and it
    // is the path they are read back out of. `hive_partitioning = false` is what
    // makes that visible — left to itself DuckDB recognises the `key=value`
    // folders and hands them back, which is the behaviour being relied on but
    // not the thing being checked here.
    let leaf = try await session.queryAll(
        "SELECT * FROM read_parquet($1, hive_partitioning = false) LIMIT 1",
        params: [destination.appendingPathComponent("category=alpha/flagged=true/*.parquet").path])
    expect(!leaf.columns.contains("category") && !leaf.columns.contains("flagged"),
           "the partition columns are not written into the files")

    let back = try await session.queryAll(
        "SELECT count(*) AS n, count(DISTINCT category) AS c FROM \(SQLBuilder.readExpression(for: .dataset(destination)))")
    expectEqual(back.value(row: 0, named: "n"), "1000", "every row is written exactly once")
    expectEqual(back.value(row: 0, named: "c"), "4", "and reading it back as a dataset restores the key")

    try? FileManager.default.removeItem(at: destination)
}

// The shape that failed in the shipped app: fifty partitions and enough rows
// that DuckDB buffers them rather than streaming straight out, which is what
// went looking for a temp directory and found `.tmp` under a read-only `/`.
//
// This checks the export, not the spill. Whether a given run actually spills is
// DuckDB's call — it depends on the memory limit and the machine's core count,
// and a test that leans on tipping that balance would stop testing anything the
// day the heuristic moves. What guards the fix is the `temp_directory`
// assertion in "Engine round-trip"; this guards the export it surfaced through.
do {
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-spill")
    try? FileManager.default.removeItem(at: destination)

    let wide = BoundSQL(
        sql: """
            SELECT i AS id, hash(i) % 50 AS bucket, repeat('x', 100) AS pad \
            FROM range(300000) t(i)
            """,
        params: []
    )
    let copy = SQLBuilder.export(
        query: wide, to: destination, format: .parquet,
        layout: SQLBuilder.ParquetLayout(partitionBy: ["bucket"]))
    try await session.execute(copy.sql, params: copy.params)

    let back = try await session.queryAll(
        "SELECT count(*) AS n, count(DISTINCT bucket) AS b FROM \(SQLBuilder.readExpression(for: .dataset(destination)))")
    expectEqual(back.value(row: 0, named: "n"), "300000", "a many-partition export writes every row")
    expectEqual(back.value(row: 0, named: "b"), "50", "into a directory per distinct key")
    try? FileManager.default.removeItem(at: destination)
}

// The ORDER BY field. It decides the order rows are *written* in — which is
// what makes a parquet file compress — without disturbing which rows those are.
do {
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-ordered.parquet")
    try? FileManager.default.removeItem(at: destination)

    let query = SQLBuilder.rows(source: .file(smallParquet), sort: [SortKey(column: "id", direction: .ascending)])
    let layout = SQLBuilder.ParquetLayout(orderBy: "  score DESC  ")
    expectEqual(layout.trimmedOrderBy, "score DESC", "surrounding whitespace is not part of the clause")
    expectEqual(SQLBuilder.ParquetLayout(orderBy: "   ").trimmedOrderBy, nil,
                "an untouched field adds no ORDER BY at all")

    let copy = SQLBuilder.export(
        query: query, to: destination, format: .parquet, limit: 10, layout: layout)
    try await session.execute(copy.sql, params: copy.params)

    // The cap is applied before the reordering, so the rows written are the ten
    // the grid is showing — ids 0 through 9 — rearranged, not the ten with the
    // highest scores in the whole file.
    let written = try await session.queryAll(
        "SELECT id, score FROM read_parquet($1)", params: [destination.path])
    expectEqual(written.rowCount, 10, "the limit still names the rows on screen")
    expectEqual(written.column("id").compactMap { $0.flatMap(Int.init) }.sorted(), Array(0..<10),
                "and they are those rows, not the file's ten highest scores")
    let scores = written.column("score").compactMap { $0.flatMap(Int.init) }
    expectEqual(scores, scores.sorted(by: >), "the file's row order is the ordering that was asked for")

    // Ordering is parquet's alone: the other formats are handed to COPY without it.
    let asCSV = SQLBuilder.export(
        query: query, to: destination, format: .csv, limit: 10, layout: layout)
    expect(!asCSV.sql.contains("ORDER BY score"), "a CSV export ignores the parquet layout")

    try? FileManager.default.removeItem(at: destination)
}

// The codec. DuckDB's own default is Snappy; DuckParq's is ZSTD, on the grounds
// that an export is written once and read many times.
do {
    let query = SQLBuilder.rows(source: .file(smallParquet))
    expectEqual(SQLBuilder.ParquetLayout().compression, .zstd, "ZSTD unless asked otherwise")

    var written: [SQLBuilder.ParquetCompression: Int] = [:]
    for codec in SQLBuilder.ParquetCompression.allCases {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("duckparq-selftest-\(codec.duckDBName).parquet")
        try? FileManager.default.removeItem(at: destination)

        let layout = SQLBuilder.ParquetLayout(orderBy: "category, label", compression: codec)
        let copy = SQLBuilder.export(query: query, to: destination, format: .parquet, layout: layout)
        expect(copy.sql.contains("COMPRESSION \(codec.duckDBName)"),
               "the codec is named in the COPY for \(codec.rawValue)")
        try await session.execute(copy.sql, params: copy.params)

        // Read back from the footer rather than trusted: this is the one place
        // that says what the file is actually encoded with.
        let stored = try await session.queryAll(
            "SELECT DISTINCT compression FROM parquet_metadata($1)", params: [destination.path])
        expectEqual(stored.column("compression").compactMap { $0?.uppercased() }.sorted(),
                    [codec == .uncompressed ? "UNCOMPRESSED" : codec.rawValue.uppercased()],
                    "and every column of the file is written with it")

        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        written[codec] = size
        try? FileManager.default.removeItem(at: destination)
    }
    expect(written[.zstd]! < written[.uncompressed]!, "which is the point: ZSTD is smaller than none")
    expect(written[.zstd]! < written[.snappy]!, "and smaller than the default it replaces")

    // Only parquet has a codec. CSV's own COMPRESSION means gzip on the whole
    // file, which is not what this option is, so it is never passed on.
    let asCSV = SQLBuilder.export(
        query: query, to: URL(fileURLWithPath: "/dev/null"), format: .csv,
        layout: SQLBuilder.ParquetLayout(compression: .gzip))
    expect(!asCSV.sql.contains("COMPRESSION"), "a CSV export is not handed a parquet codec")
}

// The ORDER BY is the one part of an export a person writes as text, so it is
// checked before it runs — as a SELECT, which is a thing DuckDB can both parse
// and bind. A second statement hidden past a semicolon is rejected as such, and
// a column that does not exist is named before anything reaches the disk.
do {
    let query = SQLBuilder.rows(source: .file(smallParquet))

    let honest = SQLBuilder.exportCheck(query: query, limit: 10, orderBy: "score DESC, id")
    try await session.validateReadOnly(honest)

    let smuggled = SQLBuilder.exportCheck(query: query, orderBy: "id; CREATE TABLE sneaky (x INT)")
    do {
        try await session.validateReadOnly(smuggled)
        expect(false, "a semicolon in the ORDER BY field is refused")
    } catch let error as SQLPolicyError {
        expectEqual(error, .multipleStatements(2), "and is refused for being two statements")
    }

    // The check binds as well as parses, which is why the path is written into
    // it: a statement whose source is still an unbound `$1` has no schema to
    // resolve a column name against, so it would pass and fail at COPY time.
    let misspelled = SQLBuilder.exportCheck(query: query, orderBy: "no_such_column")
    do {
        try await session.validateReadOnly(misspelled)
        expect(false, "an unknown column is caught before the export runs")
    } catch {
        expect("\(error)".contains("no_such_column"), "and the message names it, got \(error)")
    }

    let empty = SQLBuilder.exportCheck(query: query, limit: 10, orderBy: nil)
    try await session.validateReadOnly(empty)
}

// MARK: - SQL trace

section("SQL trace")

do {
    // The trace is a diagnostic, so the properties worth holding are that it
    // is silent unless asked for, and that when asked for it emits something
    // that can be run. Whether it is on for this process is decided by the
    // environment at launch, so the suite checks whichever half applies rather
    // than trying to flip it underneath itself.
    if SQLTrace.isEnabled {
        let ticket = SQLTrace.begin(session: "selftest-trace", sql: "SELECT $1", params: ["x"])
        expect(ticket != nil, "an enabled trace issues a ticket")
        SQLTrace.finish(ticket, rows: 1)
    } else {
        expect(SQLTrace.begin(session: "off", sql: "SELECT 1", params: []) == nil,
               "tracing off issues no ticket, so nothing is written")
        SQLTrace.finish(nil)
        expect(true, "finishing a nil ticket is a no-op rather than a crash")
    }

    // What the trace writes is `inlined`, and the reason it writes that rather
    // than the bound form is that the line has to be runnable. That property
    // belongs to the substitution, so it is asserted on a statement shaped
    // like the ones the grid actually issues -- a path parameter inside a
    // quoted literal, which is where a naive substitution goes wrong.
    let bound = SQLBuilder.rows(source: .file(smallParquet),
                                sort: [SortKey(column: "id", direction: .descending)])
    let runnable = SQLBuilder.inlined(BoundSQL(sql: bound.sql, params: bound.params))
    expect(!runnable.contains("$1"), "a traced statement carries no unsubstituted placeholders")
    expect(runnable.contains(smallParquet.path), "and names the file it read")

    // The real check: DuckDB accepts it.
    let echoed = try await session.queryAll(runnable, limit: 1)
    expectEqual(echoed.rowCount, 1, "a traced statement runs as written")
}

// MARK: - Page addressing

section("Page addressing")

do {
    // Which end of the result a page is counted from. The point is that a page
    // near the end is reached by counting back from the end, so the last page
    // of three billion rows is offset 0 and the one before it offset 500 --
    // rather than offsets of three billion, which DuckDB can only satisfy by
    // producing and discarding everything in front of them.
    typealias Address = TableModel.PageAddress
    let billions = 3_131_875_121

    expectEqual(TableModel.pageAddress(start: billions - 500, count: 500,
                                       total: billions, invertible: true),
                Address.reversed(offset: 0),
                "the last page is at the far end's offset 0, not the near end's three billion")
    expectEqual(TableModel.pageAddress(start: billions - 1000, count: 500,
                                       total: billions, invertible: true),
                Address.reversed(offset: 500),
                "the page before it is 500 back from the end")
    expectEqual(TableModel.pageAddress(start: billions - 1500, count: 500,
                                       total: billions, invertible: true),
                Address.reversed(offset: 1000),
                "and the one before that 1000, counting away from the end")

    // The first page is already at the near end, so counting forward wins.
    expectEqual(TableModel.pageAddress(start: 0, count: 500, total: 1000, invertible: true),
                Address.forward(offset: 0), "the first page is counted forward")

    // The crossover is the midpoint: past it, forward is the shorter way again.
    expectEqual(TableModel.pageAddress(start: 400, count: 100, total: 1000, invertible: true),
                Address.forward(offset: 400), "a page before the midpoint is counted forward")
    expectEqual(TableModel.pageAddress(start: 600, count: 100, total: 1000, invertible: true),
                Address.reversed(offset: 300), "a page past the midpoint is counted back")

    // Without a sort there is no order to run backward, and without a total
    // there is nothing to measure the far end against.
    expectEqual(TableModel.pageAddress(start: billions - 500, count: 500,
                                       total: billions, invertible: false),
                Address.forward(offset: billions - 500),
                "an unsorted result can only be counted forward, however far in")
    expectEqual(TableModel.pageAddress(start: 900, count: 100, total: nil, invertible: true),
                Address.forward(offset: 900),
                "an uncounted result cannot be addressed from its end")

    // A page running past the end would give a negative offset backward.
    expectEqual(TableModel.pageAddress(start: 900, count: 500, total: 1000, invertible: true),
                Address.forward(offset: 900), "a page overrunning the end is counted forward")
}

// MARK: - Row summary

section("Row summary")

do {
    // The opening window is unchanged: it starts at row 0, so the loaded count
    // already says everything -- "500 of 3,000" means the first 500.
    expectEqual(RowSummary.text(loaded: 500, windowStart: 0, total: 3000),
                "500 of 3,000 rows", "a window at the top reports what it has loaded")

    // A window anchored at the end must not report the same thing. Saying
    // "500 of 3,000" there tells the reader they are at the front of the file
    // when they are looking at the back of it -- the count of loaded rows says
    // nothing about which rows those are.
    expectEqual(RowSummary.text(loaded: 500, windowStart: 2500, total: 3000),
                "2,501–3,000 of 3,000 rows", "the last page reports where it sits, counted from the total")

    // Scrolling up from there widens the window backward, and the range grows
    // from its near end rather than the loaded count simply going up.
    expectEqual(RowSummary.text(loaded: 1000, windowStart: 2000, total: 3000),
                "2,001–3,000 of 3,000 rows", "a backward step extends the range, not just the count")

    // Walking all the way back to row 0 lands on the whole result again.
    expectEqual(RowSummary.text(loaded: 3000, windowStart: 0, total: 3000),
                "3,000 rows", "a window holding everything just says how much that is")

    // A short tail: 700 rows anchor their last page at 200, so the range runs
    // 201 to 700 and not 201 to 700-of-something-else.
    expectEqual(RowSummary.text(loaded: 500, windowStart: 200, total: 700),
                "201–700 of 700 rows", "a result that is not a whole number of pages still adds up")

    // Before the count lands there is no total to measure against.
    expectEqual(RowSummary.text(loaded: 500, windowStart: 0, total: nil),
                "500 rows loaded", "with no count there is only what is loaded")
    expectEqual(RowSummary.text(loaded: 500, windowStart: 2500, total: nil),
                "500 rows loaded", "including when the window has been moved")

    // An empty result spans nothing, so there is no range to report.
    expectEqual(RowSummary.text(loaded: 0, windowStart: 0, total: 0),
                "0 rows", "an empty result reports itself as empty")
}

// MARK: - Hive page index

// The order a hive dataset is paged in, and the arithmetic that turns a row
// offset into a file to read. Both are pure, so they are checked here without a
// database; the end-to-end behaviour is in "Paging integrity".

section("Hive page index")

do {
    typealias File = HivePageIndex.File
    func file(_ path: String, _ rows: Int, _ values: [String?]) -> File {
        File(path: path, totalRows: rows, partitionValues: values)
    }

    // Sorting the paths as plain text is the trap this ordering exists to
    // avoid. DuckDB types a hive key -- `month` comes back BIGINT -- so
    // `ORDER BY month` counts 1, 2, … 10, 11, 12 while the paths sort
    // `month=1`, `month=10`, `month=11`, `month=12`, `month=2`. Paging in path
    // order would put the rows in an order the sort in the header contradicts,
    // and would disagree with what exporting the same view produces.
    let months = (1...12).map { file("/d/month=\($0)/f.parquet", 10, ["\($0)"]) }
    let orderedMonths = HivePageIndex.order(months.shuffled(), keyCount: 1)
    expectEqual(orderedMonths.map { $0.partitionValues[0] }, (1...12).map { "\($0)" },
                "a numeric partition key orders as numbers, not as text")

    // Where the values are not all numbers, text order is the right answer --
    // that is what DuckDB infers the column as.
    let regions = ["us", "eu", "apac"].map { (value: String) in
        file("/d/region=\(value)/f.parquet", 10, [value])
    }
    expectEqual(HivePageIndex.order(regions, keyCount: 1).map { $0.partitionValues[0] },
                ["apac", "eu", "us"], "a text partition key orders lexicographically")

    // Mixed values are text too: one non-numeric value is what makes DuckDB
    // read the whole column as VARCHAR.
    let mixed = ["10", "9", "later"].map { (value: String) in
        file("/d/k=\(value)/f.parquet", 10, [value])
    }
    expectEqual(HivePageIndex.order(mixed, keyCount: 1).map { $0.partitionValues[0] },
                ["10", "9", "later"], "a key with any non-numeric value orders as text")

    // Nesting: the outer key decides first, the inner one breaks it, and the
    // path breaks that.
    let nested = [
        file("/d/year=2024/region=us/f.parquet", 1, ["2024", "us"]),
        file("/d/year=2023/region=us/b.parquet", 1, ["2023", "us"]),
        file("/d/year=2023/region=eu/f.parquet", 1, ["2023", "eu"]),
        file("/d/year=2023/region=us/a.parquet", 1, ["2023", "us"]),
    ]
    expectEqual(HivePageIndex.order(nested, keyCount: 2).map(\.path), [
        "/d/year=2023/region=eu/f.parquet",
        "/d/year=2023/region=us/a.parquet",
        "/d/year=2023/region=us/b.parquet",
        "/d/year=2024/region=us/f.parquet",
    ], "partitions order outermost key first, then by file name")

    // A NULL partition is written `__HIVE_DEFAULT_PARTITION__` on disk, and
    // DuckDB sorts NULL last ascending. Ordering it as the literal string would
    // drop it in among the `_`-prefixed values instead.
    let withNull = [
        file("/d/g=__HIVE_DEFAULT_PARTITION__/f.parquet", 1, [nil]),
        file("/d/g=3/f.parquet", 1, ["3"]),
        file("/d/g=1/f.parquet", 1, ["1"]),
    ]
    expectEqual(HivePageIndex.order(withNull, keyCount: 1).map { $0.partitionValues[0] },
                ["1", "3", nil], "a NULL partition sorts last, matching DuckDB's NULLS LAST")

    // Parsing a path back into its partition values, which is where the
    // sentinel becomes a real nil.
    let root = URL(fileURLWithPath: "/data/events")
    let parsed = HivePageIndex.partitionComponents(
        of: "/data/events/year=2024/region=__HIVE_DEFAULT_PARTITION__/part-0.parquet", under: root)
    expectEqual(parsed.keys, ["year", "region"], "the keys come off the path outermost first")
    expectEqual(parsed.values, ["2024", nil], "and the default-partition sentinel reads as NULL")

    // A value may itself contain '=' -- only the first one separates.
    let equals = HivePageIndex.partitionComponents(
        of: "/data/events/expr=a=b/part-0.parquet", under: root)
    expectEqual(equals.values, ["a=b"], "only the first = separates key from value")

    // Turning a row range into file reads. Three files of 500 rows: a page
    // wholly inside one file, a page spanning a boundary, and the tail.
    let counts = [500, 500, 500]
    expectEqual(HivePageIndex.spans(start: 0, count: 500, rowCounts: counts),
                [HivePageIndex.Span(file: 0, offset: 0, count: 500)],
                "a page that fills one file is one read")
    expectEqual(HivePageIndex.spans(start: 400, count: 300, rowCounts: counts),
                [HivePageIndex.Span(file: 0, offset: 400, count: 100),
                 HivePageIndex.Span(file: 1, offset: 0, count: 200)],
                "a page across a file boundary is two reads, in order")
    expectEqual(HivePageIndex.spans(start: 1000, count: 500, rowCounts: counts),
                [HivePageIndex.Span(file: 2, offset: 0, count: 500)],
                "the tail page reads only the last file")
    expectEqual(HivePageIndex.spans(start: 1400, count: 500, rowCounts: counts),
                [HivePageIndex.Span(file: 2, offset: 400, count: 100)],
                "a page overrunning the end stops at the end")
    expectEqual(HivePageIndex.spans(start: 1500, count: 500, rowCounts: counts), [],
                "a page starting past the end reads nothing")

    // A file every row of which a filter excluded contributes nothing, and must
    // not shift the rows after it.
    expectEqual(HivePageIndex.spans(start: 0, count: 30, rowCounts: [10, 0, 40]),
                [HivePageIndex.Span(file: 0, offset: 0, count: 10),
                 HivePageIndex.Span(file: 2, offset: 0, count: 20)],
                "an empty file is skipped rather than counted")
}

// MARK: - Hive summary

// What the schema panel says about a partitioned dataset. Read from the paths
// alone, so it is checked here without a database; the read that produces those
// paths is exercised against the fixture in "Probes".

section("Hive summary")

do {
    let root = URL(fileURLWithPath: "/data/weather")
    func paths(_ years: [String], _ elements: [String]) -> [String] {
        years.flatMap { year in
            elements.map { "/data/weather/year=\(year)/element=\($0)/data_0.parquet" }
        }
    }

    let summary = HiveSummary.summarize(
        paths: paths(["2022", "2023", "2024"], ["TMAX", "TMIN"]), under: root)
    expectEqual(summary?.keys.map(\.name), ["year", "element"],
                "the keys are reported outermost first, as they nest on disk")
    expectEqual(summary?.keys.map(\.distinctValues), [3, 2],
                "each key reports how many distinct values it takes")
    expectEqual(summary?.partitionCount, 6, "and the partitions are the combinations on disk")

    // The counts are per key across the whole dataset, and the partition count
    // is what exists rather than the product of them. A key present under one
    // parent and absent under another is the ordinary shape of a real archive.
    let ragged = HiveSummary.summarize(
        paths: paths(["2022"], ["TMAX", "TMIN", "PRCP"]) + paths(["2023"], ["TMAX"]),
        under: root)
    expectEqual(ragged?.keys.map(\.distinctValues), [2, 3],
                "a value seen under any parent counts once for its key")
    expectEqual(ragged?.partitionCount, 4,
                "partitions are counted, not multiplied out of the key cardinalities")

    // A NULL partition is a partition, and its sentinel spelling is not a value
    // of its own to be reported alongside the real ones.
    let withNull = HiveSummary.summarize(
        paths: ["/data/weather/year=2024/element=TMAX/d.parquet",
                "/data/weather/year=2024/element=\(HivePageIndex.nullPartition)/d.parquet"],
        under: root)
    expectEqual(withNull?.keys.map(\.distinctValues), [1, 2],
                "a NULL partition counts as one of its key's values")
    expectEqual(withNull?.partitionCount, 2, "and as a partition of its own")

    // Several files in one partition describe one partition.
    let manyFiles = HiveSummary.summarize(
        paths: (0..<5).map { "/data/weather/year=2024/element=TMAX/data_\($0).parquet" },
        under: root)
    expectEqual(manyFiles?.partitionCount, 1, "a partition of many files is still one partition")

    // Nothing to describe: a folder of plain files, and a layout whose files
    // disagree about what they are partitioned by. Both are cases where there
    // is no single hierarchy, and the panel shows no section rather than a
    // made-up one.
    expectEqual(HiveSummary.summarize(paths: ["/data/weather/part-0.parquet"], under: root),
                HiveSummary?.none, "a folder of unpartitioned files has no hive schema")
    expectEqual(
        HiveSummary.summarize(
            paths: ["/data/weather/year=2024/element=TMAX/d.parquet",
                    "/data/weather/year=2024/d.parquet"],
            under: root),
        HiveSummary?.none, "files at disagreeing depths describe no one hierarchy")
    expectEqual(
        HiveSummary.summarize(
            paths: ["/data/weather/year=2024/element=TMAX/d.parquet",
                    "/data/weather/year=2024/station=USW/d.parquet"],
            under: root),
        HiveSummary?.none, "and neither do files partitioned by different keys")
    expectEqual(HiveSummary.summarize(paths: [], under: root), HiveSummary?.none,
                "an empty listing describes nothing")
}

// MARK: - Grid scrolling

section("Grid scrolling")

do {
    // Every move the grid makes on the user's behalf names both axes, because
    // the SwiftUI calls that name only one -- `scrollTo(edge:)` and
    // `scrollTo(y:)` -- return the horizontal offset to zero as they go. That
    // is a bug you see rather than read: Home or End on a file wider than the
    // window moved the rows as asked and walked the columns back to the first
    // one at the same time. So the x asked for is always the x the columns are
    // already at.
    let columns: CGFloat = 268

    expectEqual(GridScroll.landing(on: .top, keepingX: columns),
                GridScroll.Landing(x: columns, y: 0),
                "Home lands on the first row without moving the columns")
    expectEqual(GridScroll.landing(on: .bottom, keepingX: columns).x, columns,
                "and End leaves them alone too")
    expectEqual(GridScroll.landing(on: .bottom, keepingX: 0).x, 0,
                "a grid resting at the left edge stays there")

    // The bottom is deliberately not a measured height. A landing is asked for
    // just after the rows were replaced, when a measured content height would
    // still describe the window that has gone; a y past any content is clamped
    // by the scroll view against the rows as actually laid out. "Past any
    // content" has to mean it for a file of any size -- three billion rows of
    // 20 points is 6e10, and this is many orders past that.
    expect(GridScroll.landing(on: .bottom, keepingX: columns).y > 1e30,
           "End asks for a y beyond any content there could be, and is clamped to the real end")

    // Holding the reading position across a page of earlier rows. The case the
    // bug was reported from is the first one: scrolling up to the top is how
    // the page gets asked for, so the viewport is at zero when it arrives, and
    // without the shift there is no "up" left to ask for the next one with.
    expectEqual(GridScroll.offsetAfterPrepend(from: 0, prepended: 500, rowHeight: 20),
                10_000,
                "a viewport at the top gains the whole prepended page to scroll back up through")
    expectEqual(GridScroll.offsetAfterPrepend(from: 2_000, prepended: 500, rowHeight: 20),
                12_000,
                "and one further down keeps the rows it was reading under the eye")
    // The last step back to row 0 is however much of a page is left.
    expectEqual(GridScroll.offsetAfterPrepend(from: 640, prepended: 200, rowHeight: 20),
                4_640,
                "a short page shifts by what it actually brought")
    expectEqual(GridScroll.offsetAfterPrepend(from: 3_000, prepended: 0, rowHeight: 20),
                3_000,
                "and a page that brought nothing moves the viewport not at all")
}

do {
    // Page Up and Page Down: a step of a screenful from wherever the viewport
    // is, rather than a place to land. The columns are held for the same reason
    // Home and End hold them -- the press moves the rows and says nothing about
    // the columns.
    let columns: CGFloat = 268
    let viewport: CGFloat = 600
    let row: CGFloat = 20

    expectEqual(GridScroll.pageStep(viewportHeight: viewport, rowHeight: row), 580,
                "a page is a screenful less the one row of overlap that keeps the reading position visible")
    expectEqual(GridScroll.pageStep(viewportHeight: 24, rowHeight: row), 20,
                "a viewport barely taller than a row still moves a whole row")
    expectEqual(GridScroll.pageStep(viewportHeight: 0, rowHeight: row), 20,
                "and one not laid out yet moves forward rather than backward")

    expectEqual(GridScroll.page(.down, from: 0, viewportHeight: viewport,
                                rowHeight: row, keepingX: columns),
                GridScroll.Landing(x: columns, y: 580),
                "Page Down moves a page down the rows without moving the columns")
    expectEqual(GridScroll.page(.up, from: 580, viewportHeight: viewport,
                                rowHeight: row, keepingX: columns),
                GridScroll.Landing(x: columns, y: 0),
                "and Page Up brings it back to exactly where it started")
    expectEqual(GridScroll.page(.up, from: 100, viewportHeight: viewport,
                                rowHeight: row, keepingX: columns).y,
                0,
                "paging up from less than a page in stops at the top rather than above it")
    expectEqual(GridScroll.page(.up, from: 0, viewportHeight: viewport,
                                rowHeight: row, keepingX: columns).y,
                0,
                "and a viewport already at the top has nowhere to go -- which is what tells the grid to ask for earlier rows instead")

    // The far end is the scroll view's to clamp, against the rows as laid out.
    // Anything measured here would describe the window before the last page
    // landed, which is exactly when a page down is most likely to be pressed.
    expectEqual(GridScroll.page(.down, from: 9_900, viewportHeight: viewport,
                                rowHeight: row, keepingX: 0).y,
                10_480,
                "Page Down asks past the end and lets the scroll view stop it at the real one")
}

do {
    // The arrows with no row selected: a way to move the view, and the only key
    // the grid answers that moves it sideways. Vertically the step is one row,
    // so the top edge always lands on a row boundary rather than slicing one.
    let columns: CGFloat = 268
    let row: CGFloat = 20
    let step = GridScroll.arrowColumnStep

    expectEqual(GridScroll.arrow(.down, fromY: 100, x: columns, rowHeight: row),
                GridScroll.Landing(x: columns, y: 120),
                "the down arrow moves one row down and leaves the columns where they were")
    expectEqual(GridScroll.arrow(.up, fromY: 100, x: columns, rowHeight: row),
                GridScroll.Landing(x: columns, y: 80),
                "and the up arrow moves one row back")
    expectEqual(GridScroll.arrow(.up, fromY: 0, x: columns, rowHeight: row).y, 0,
                "a viewport already at the top has nowhere further up to go -- which is what tells the grid to ask for earlier rows instead")

    expectEqual(GridScroll.arrow(.right, fromY: 100, x: columns, rowHeight: row),
                GridScroll.Landing(x: columns + step, y: 100),
                "the right arrow moves the columns and leaves the rows alone")
    expectEqual(GridScroll.arrow(.left, fromY: 100, x: columns, rowHeight: row),
                GridScroll.Landing(x: columns - step, y: 100),
                "and the left arrow brings them back")
    expectEqual(GridScroll.arrow(.left, fromY: 100, x: 10, rowHeight: row).x, 0,
                "stopping at the first column rather than to the left of it")
}

do {
    // Bringing a stepped-to row back into view. Nil is the answer worth having:
    // arrowing through the middle of a screenful must leave the view perfectly
    // still, and "scroll to where you already are" is not still.
    let columns: CGFloat = 268
    let row: CGFloat = 20
    let viewport: CGFloat = 600

    // A window starting at row 1_000, scrolled 200 points into it: rows 1_010
    // through 1_039 are on screen.
    let start = 1_000
    let top: CGFloat = 200

    expect(GridScroll.reveal(rowAt: 1_020, windowStart: start, rowHeight: row,
                             distanceFromTop: top, viewportHeight: viewport,
                             keepingX: columns) == nil,
           "a row in the middle of the viewport needs no scrolling at all")
    expect(GridScroll.reveal(rowAt: 1_010, windowStart: start, rowHeight: row,
                             distanceFromTop: top, viewportHeight: viewport,
                             keepingX: columns) == nil,
           "nor does the first row fully on screen")
    expect(GridScroll.reveal(rowAt: 1_039, windowStart: start, rowHeight: row,
                             distanceFromTop: top, viewportHeight: viewport,
                             keepingX: columns) == nil,
           "nor the last one")

    // Just off an edge, brought just inside it: a selection moving a row at a
    // time should scroll a row at a time, not jump half a screen each time it
    // reaches the bottom.
    expectEqual(GridScroll.reveal(rowAt: 1_009, windowStart: start, rowHeight: row,
                                  distanceFromTop: top, viewportHeight: viewport,
                                  keepingX: columns),
                GridScroll.Landing(x: columns, y: 180),
                "a step above the top edge scrolls up by exactly one row")
    expectEqual(GridScroll.reveal(rowAt: 1_040, windowStart: start, rowHeight: row,
                                  distanceFromTop: top, viewportHeight: viewport,
                                  keepingX: columns),
                GridScroll.Landing(x: columns, y: 220),
                "and a step below the bottom edge scrolls down by exactly one")

    // The row id is an offset into the whole result, so the window it sits in
    // has to be subtracted -- a window anchored at row 1_000 draws its own first
    // row at y = 0, not at y = 20_000.
    expectEqual(GridScroll.reveal(rowAt: start, windowStart: start, rowHeight: row,
                                  distanceFromTop: top, viewportHeight: viewport,
                                  keepingX: columns),
                GridScroll.Landing(x: columns, y: 0),
                "the first row of a window anchored deep in the result is at the top of the content")
    expectEqual(GridScroll.reveal(rowAt: 500, windowStart: start, rowHeight: row,
                                  distanceFromTop: top, viewportHeight: viewport,
                                  keepingX: columns)?.y,
                0,
                "and a row from before the window cannot ask to be scrolled above it")

    // Before the scroll view has been laid out the grid reports a viewport of
    // zero, which has no inside of a bottom edge to land against.
    expectEqual(GridScroll.reveal(rowAt: 1_030, windowStart: start, rowHeight: row,
                                  distanceFromTop: top, viewportHeight: 0,
                                  keepingX: columns),
                GridScroll.Landing(x: columns, y: 600),
                "a viewport too short to hold a row puts that row's top at the top")
}

// MARK: - Grid selection

section("Grid selection")

do {
    // With a row selected the grid is a list and the arrows step through it.
    // The ends they run into are the ends of the *loaded window*, which are not
    // the ends of the result -- so one of them is a request for rows rather than
    // a refusal.
    let start = 1_000
    let loaded = 500  // rows 1_000 through 1_499

    expectEqual(GridSelection.move(.down, from: 1_200, windowStart: start, loadedRows: loaded),
                .select(1_201),
                "the down arrow takes the next row")
    expectEqual(GridSelection.move(.up, from: 1_200, windowStart: start, loadedRows: loaded),
                .select(1_199),
                "and the up arrow the previous one")

    expectEqual(GridSelection.move(.up, from: start, windowStart: start, loadedRows: loaded),
                .loadEarlier,
                "stepping up off the front of a window that starts partway through the result asks for the rows above it")
    expectEqual(GridSelection.move(.up, from: 0, windowStart: 0, loadedRows: loaded),
                .stay,
                "but the first row of the result itself has nothing above it")
    expectEqual(GridSelection.move(.down, from: 1_499, windowStart: start, loadedRows: loaded),
                .stay,
                "and stepping down off the end waits for the next page rather than guessing at a row that is not there")

    // A window can be paged out from under a selection -- jumping to the end of
    // three billion rows leaves one behind at row 3. The press still means "move
    // from here", so the nearest loaded row is where "here" now is.
    expectEqual(GridSelection.move(.down, from: 3, windowStart: start, loadedRows: loaded),
                .select(start),
                "a selection left behind above the window lands on its first row")
    expectEqual(GridSelection.move(.up, from: 9_000, windowStart: start, loadedRows: loaded),
                .select(1_499),
                "and one left behind below it lands on its last")

    expectEqual(GridSelection.move(.down, from: 0, windowStart: 0, loadedRows: 0),
                .stay,
                "an empty result has no row to move to")
    expectEqual(GridSelection.move(.down, from: 0, windowStart: 0, loadedRows: 1),
                .stay,
                "and a result of one row is already on the only row there is")
}

do {
    // Which sidebar clicks let go of the selected row: the ones landing on the
    // list but on none of its rows. Against a real table view, because the whole
    // difficulty is that the cheaper ways of asking are wrong -- see
    // `SidebarHit`, where three of them are written out.
    //
    // A table three rows tall in a view far taller than they are, which is the
    // shape SwiftUI actually produces: the document view fills the viewport
    // whether or not there are rows to fill it, so the empty area below the rows
    // is *inside* it.
    let rows = NSTableView()
    rows.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    rows.rowHeight = 20
    rows.dataSource = ThreeRows.shared
    // In a scroll view, because that is what produces the shape this is about: a
    // table view standing on its own shrinks to fit its rows, and one in a
    // viewport stretches to fill it. Only the second has an empty area at all.
    let viewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    viewport.documentView = rows
    rows.reloadData()
    viewport.layoutSubtreeIfNeeded()

    expectEqual(rows.numberOfRows, 3, "the fixture has the rows it says it has")
    expect(rows.bounds.height > rows.rect(ofRow: 2).maxY + 100,
           "and stretches well past them, the way SwiftUI's own does")
    let lastRow = rows.rect(ofRow: 2)
    expect(SidebarHit.isEmptyArea(CGPoint(x: 130, y: lastRow.minY - 20), in: rows) == false,
           "a click on a row is a click on a row")
    expect(SidebarHit.isEmptyArea(CGPoint(x: 130, y: lastRow.midY), in: rows) == false,
           "and so is one on the last of them")
    expect(SidebarHit.isEmptyArea(CGPoint(x: 130, y: lastRow.maxY + 100), in: rows),
           "past the end of them is the empty area -- the click that lets go of the selected row")

    // Everywhere outside the rows' own view means its own thing: the strip the
    // list scrolls under the toolbar above it, and the grid beside it, where a
    // click is how a row gets selected in the first place.
    expect(SidebarHit.isEmptyArea(CGPoint(x: 130, y: -20), in: rows) == false,
           "the toolbar the list scrolls under is not an empty area of the list")
    expect(SidebarHit.isEmptyArea(CGPoint(x: 600, y: 200), in: rows) == false,
           "and neither is anything beside the sidebar")
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
        // all four are done -- otherwise assertions race the counter.
        if !model.isLoading && !model.isLoadingMore && !model.isLoadingEarlier && !model.isCountingRows {
            return
        }
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

    // End: jump to the last page and anchor there, rather than reading the
    // whole file to get to the bottom.
    expectEqual(model.windowStart, 0, "starting from the opening window")
    expectEqual(model.prependedRowCount, 0, "an opening window added nothing above itself")
    model.jumpToEnd()
    await settle(model)
    expectEqual(model.prependedRowCount, 0, "landing on the end is not a prepend")
    expectEqual(model.rows.count, TableModel.pageSize, "jumping to the end loads one page, not the whole file")
    expectEqual(model.windowStart, 500, "the tail window starts a page before the file's last row")
    expect(model.reachedEnd, "the tail window already reaches the last row")
    expect(!model.reachedStart, "the tail window does not also reach row 0")
    expectEqual(model.rows.map(\.id), Array(500..<1000), "row ids reflect each row's true offset in the file")
    expectEqual(model.rows.last?.cells[idIndex], "999", "the last row loaded is the file's actual last row")

    // What the status bar says about that window, taken from the model rather
    // than from hand-picked numbers -- the summary is only right if
    // `windowStart` means what it is read as meaning here.
    expectEqual(RowSummary.text(loaded: model.rows.count,
                                windowStart: model.windowStart,
                                total: model.totalRowCount),
                "501–1,000 of 1,000 rows",
                "landing on the end says which rows those are, not that 500 are loaded")

    model.loadEarlier()
    await settle(model)
    expectEqual(RowSummary.text(loaded: model.rows.count,
                                windowStart: model.windowStart,
                                total: model.totalRowCount),
                "1,000 rows", "and stepping back to row 0 has the whole file loaded")
    model.jumpToEnd()
    await settle(model)

    // Landing on the end must be one query and stay one query. Rendering the
    // window cannot pull in another page: every row of it is handed to
    // `loadMoreIfNeeded`, which is the call the grid makes as rows appear, and
    // none of them may page backward. This is what turned one five-second read
    // into two on a billion-row dataset -- a `LazyVStack` fills from the top,
    // so the rows realised on arrival look exactly like the user having
    // scrolled to the top of the window.
    let generationAtTail = model.rowsGeneration
    for row in model.rows {
        model.loadMoreIfNeeded(displayedIndex: row.id)
    }
    await settle(model)
    expectEqual(model.rowsGeneration, generationAtTail, "landing on the end runs one query, not several")
    expectEqual(model.windowStart, 500, "rendering the tail window cannot page backward")
    expectEqual(model.rows.count, TableModel.pageSize, "and the tail window is left as it landed")

    // Scrolling up from the tail must load in earlier rows the same way
    // scrolling down from the top does, not by re-reading everything. The
    // grid asks for this explicitly, off an upward scroll -- it is the one
    // path backward, and nothing about drawing rows can reach it.
    model.loadEarlier()
    await settle(model)
    expectEqual(model.rows.count, 1000, "scrolling up from the tail eventually reaches the front of the file")
    expectEqual(model.windowStart, 0, "loading earlier rows all the way back reaches row 0")
    expect(model.reachedStart, "row 0 loaded means the window reaches the start")
    expect(model.reachedEnd, "the tail end is untouched by loading earlier rows")
    expectEqual(model.rows.map(\.id), Array(0..<1000), "row ids stay contiguous across a prepend")
    expectEqual(model.rows.first?.cells[idIndex], "0", "the first row loaded is the file's actual first row")

    // How many rows arrived above the ones already there, which is what the
    // grid shifts its viewport by to stay where it was. Without that shift the
    // rows being read jump backward by a page, and — since scrolling up to the
    // top is how the page was asked for in the first place — the viewport is
    // left against the top of the content with no further "up" to report, so
    // the page after it could not be asked for until the user scrolled back
    // down. Reported as exactly that: scrolling up loads once, then needs a
    // scroll down before it will load again.
    expectEqual(model.prependedRowCount, TableModel.pageSize,
                "a backward page reports the rows it put above the window")

    // Home after End: jumping back to the front reads a fresh opening page,
    // the same one `reload()` reads for a newly opened file -- not the whole
    // file, even though the whole file happens to be loaded right now from
    // the walk back up above.
    model.jumpToEnd()
    await settle(model)
    expectEqual(model.windowStart, 500, "back at the tail window")
    model.jumpToStart()
    await settle(model)
    expectEqual(model.windowStart, 0, "Home resets the window to the front")
    expectEqual(model.rows.count, TableModel.pageSize, "Home loads a single page, not the whole file")
    expectEqual(model.rows.map(\.id), Array(0..<TableModel.pageSize), "back to the opening window's row ids")
    expectEqual(model.rows.first?.cells[idIndex], "0", "the opening window starts at the file's first row")
    expectEqual(model.prependedRowCount, 0,
                "a window read from row 0 replaced the rows rather than growing above them")

    // Home is a no-op, query-wise, when row 0 is already loaded.
    let generationAtStart = model.rowsGeneration
    model.jumpToStart()
    expectEqual(model.rowsGeneration, generationAtStart,
                "jumpToStart does nothing when the window already reaches row 0")

    // The shift the grid applies has to match the page it actually got, which
    // is not always a full one: the last step back to row 0 is however much of
    // a page is left. A filtered result of 700 rows anchors its tail window at
    // 200, so stepping back from it prepends 200 rows and not 500.
    model.upsert(filter: Filter(column: model.column(named: "id")!, mode: .comparison(.lessThan, ["700"])))
    await settle(model)
    expectEqual(model.totalRowCount, 700, "the filter leaves a result that is not a whole number of pages")
    model.jumpToEnd()
    await settle(model)
    expectEqual(model.windowStart, 200, "the tail window of 700 rows starts a page before the last")
    model.loadEarlier()
    await settle(model)
    expectEqual(model.windowStart, 0, "stepping back from it reaches row 0")
    expectEqual(model.prependedRowCount, 200, "and reports the short page it actually prepended")
    expectEqual(model.rows.count, 700, "which joins the tail window to make the whole result")
    model.clearFilters()
    await settle(model)

    // A sorted End reads the tail by inverting the ORDER BY and turning the
    // page back over, rather than ordering the whole result to skip past it.
    // The rows it produces must be indistinguishable from what the OFFSET it
    // replaces would have returned -- same rows, same order, right way up.
    model.clearFilters()
    model.toggleSort(column: "id")
    await settle(model)
    expectEqual(model.sortDirection(for: "id"), .ascending, "sorted ascending by id")

    model.jumpToEnd()
    await settle(model)
    expectEqual(model.rows.count, TableModel.pageSize, "a sorted End still loads exactly one page")
    expectEqual(model.windowStart, 500, "anchored at the last page of the sorted result")
    expect(model.reachedEnd, "and it is the end")
    expectEqual(model.rows.first?.cells[idIndex], "500",
                "the tail page is the right way up -- lowest id of the page first")
    expectEqual(model.rows.last?.cells[idIndex], "999",
                "and runs to the highest id, not reversed")
    let sortedTailIDs = model.rows.compactMap { $0.cells[idIndex].flatMap(Int.init) }
    expectEqual(sortedTailIDs, Array(500..<1000), "the sorted tail page is ascending and contiguous")

    // Same check with the sort the other way round, where inverting means
    // ascending: the page must still read top-to-bottom in the sort's own
    // direction.
    model.toggleSort(column: "id")
    await settle(model)
    expectEqual(model.sortDirection(for: "id"), .descending, "sorted descending by id")
    model.jumpToEnd()
    await settle(model)
    let descendingTailIDs = model.rows.compactMap { $0.cells[idIndex].flatMap(Int.init) }
    expectEqual(descendingTailIDs, Array(0..<500).reversed().map { $0 },
                "the tail of a descending sort is the lowest ids, still descending")
    expectEqual(model.rows.first?.cells[idIndex], "499", "descending tail starts at 499")
    expectEqual(model.rows.last?.cells[idIndex], "0", "and ends at the file's lowest id")

    model.clearSort()
    await settle(model)

    // A hive dataset opens ordered by its top-level partition key. That order
    // is close to free -- the value comes from the path, not the data -- and
    // having one is what lets the end of the dataset be reached by counting
    // back from it rather than past everything in front of it.
    model.open(.dataset(hiveDirectory))
    await settle(model)
    expectEqual(model.sort.map(\.column), ["year"], "a hive dataset opens sorted by its partition key")
    expectEqual(model.sortDirection(for: "year"), .ascending, "ascending, so it opens at the earliest")
    expectEqual(model.defaultSort, model.sort, "and that sort is the one it opened in")
    expectEqual(model.totalRowCount, 3000, "the whole dataset is counted across its partitions")
    let yearIndex = model.columns.firstIndex { $0.name == "year" }!
    let firstYears = model.rows.prefix(20).compactMap { $0.cells[yearIndex].flatMap(Int.init) }
    expect(firstYears == firstYears.sorted(), "the opening page is ordered by the partition key")
    expectEqual(model.rows.first?.cells[yearIndex], "2023", "and starts at the earliest partition")

    // The end of it, and the page before that, which is the pair the counting
    // exists for.
    model.jumpToEnd()
    await settle(model)
    expect(model.reachedEnd, "End on a hive dataset reaches the end")
    expectEqual(model.rows.count, TableModel.pageSize, "and loads one page of it")
    expectEqual(model.windowStart, 2500, "anchored a page before the last row")
    expectEqual(model.rows.last?.cells[yearIndex], "2024", "the last row is in the latest partition")
    let tailYears = model.rows.compactMap { $0.cells[yearIndex].flatMap(Int.init) }
    expect(tailYears == tailYears.sorted(), "the tail page is turned back the right way up")

    model.loadEarlier()
    await settle(model)
    expectEqual(model.windowStart, 2000, "the page before the end loads")
    expectEqual(model.rows.count, 1000, "and joins the one already there")
    expectEqual(model.rows.map(\.id), Array(2000..<3000), "with contiguous ids across the seam")
    let joinedYears = model.rows.compactMap { $0.cells[yearIndex].flatMap(Int.init) }
    expect(joinedYears == joinedYears.sorted(), "and the two pages agree on the ordering")

    // A user clearing the sort gets the dataset unordered, so the default is a
    // starting point rather than something imposed.
    model.clearSort()
    await settle(model)
    expect(model.sort.isEmpty, "the opening sort clears like any other")
    expect(model.defaultSort != model.sort, "which is no longer the view it opened in")

    // A plain folder of parquet files is not partitioned, so it opens unsorted.
    model.open(.dataset(fixtures))
    await settle(model)
    expect(model.sort.isEmpty, "a plain folder of parquet files opens unsorted")
    expect(model.defaultSort.isEmpty, "and has no opening sort to speak of")

    model.clear()
}

// MARK: - Total order (the tiebreaker that makes a page mean one set of rows)

// `ORDER BY x` names a sequence only as far as x is unique. Where it ties, two
// executions asked for two different windows are free to break the tie two
// different ways, and the pages they return then overlap and leave gaps. The
// grid's answer is to append `read_parquet`'s virtual `file_row_number` — and,
// on a source of several files, `filename` in front of it — so the order is
// total and every window agrees about where each row sits.
//
// These checks are about the SQL and its plan. That the ordering actually holds
// end to end is "Paging integrity" below.

section("Total order")

do {
    let sorted = [SortKey(column: "flagged", direction: .ascending)]

    let plain = SQLBuilder.rows(source: .file(smallParquet), sort: sorted)
    expect(!plain.sql.contains("file_row_number"),
           "no tiebreaker is added unless one is asked for")
    expect(plain.sql.hasPrefix("SELECT * FROM"), "so the projection stays a plain SELECT *")

    let tiebroken = SQLBuilder.rows(source: .file(smallParquet), sort: sorted, tiebreak: .ascending)
    expect(tiebroken.sql.contains("file_row_number = true"),
           "the tiebreaker switches the virtual column on at the reader")
    expect(tiebroken.sql.hasSuffix("ORDER BY t.\"flagged\" ASC, t.\"file_row_number\" ASC"),
           "and follows the user's keys rather than replacing them")
    expect(tiebroken.sql.hasPrefix("SELECT * EXCLUDE (\"file_row_number\") FROM"),
           "while being projected away, so it is orderable but not a column of the grid")
    expectEqual(tiebroken.params, plain.params, "the tiebreaker binds no new parameters")

    // A single file needs no filename: `file_row_number` is already unique
    // within one, and switching the option on would only widen the read.
    expect(!tiebroken.sql.contains("filename"), "a single file tiebreaks on the row number alone")

    // Several files do. `file_row_number` restarts at 0 in each of them, so on
    // its own it is not a row's name but a name shared by one row per file.
    let dataset = SQLBuilder.rows(
        source: .dataset(hiveDirectory),
        sort: [SortKey(column: "region", direction: .ascending)],
        tiebreak: .ascending
    )
    expect(dataset.sql.contains("filename = '__duckparq_filename'"),
           "a multi-file source names the file each row came from")
    expect(dataset.sql.hasSuffix(
        "ORDER BY t.\"region\" ASC, t.\"__duckparq_filename\" ASC, t.\"file_row_number\" ASC"),
           "and puts it ahead of the per-file row number, which only means anything within one")
    expect(dataset.sql.contains("EXCLUDE (\"__duckparq_filename\", \"file_row_number\")"),
           "both are projected away")

    // Renamed rather than left as `filename` because `filename` is an ordinary
    // thing for a column to be called and DuckDB refuses to shadow one. The
    // per-file row count uses the same name for the same reason.
    expect(SQLBuilder.rowCountsByFile(source: .dataset(hiveDirectory)).sql
        .contains("filename = '__duckparq_filename'"),
           "the per-file count uses the same out-of-the-way name")

    // `fetchPage` reads a page near the end by turning the ORDER BY around. The
    // tiebreaker has to turn with it, or the inverted query describes a
    // different sequence than the forward one and the two ends disagree again.
    let inverted = SQLBuilder.rows(
        source: .file(smallParquet),
        sort: [SortKey(column: "flagged", direction: .descending)],
        tiebreak: .descending
    )
    expect(inverted.sql.hasSuffix("ORDER BY t.\"flagged\" DESC, t.\"file_row_number\" DESC"),
           "inverting the sort inverts the tiebreaker with it")

    // The hard constraint: a tiebroken window must still plan as a Top-N. The
    // whole reason sorting a file too large to sort is usable is that DuckDB
    // keeps `limit` rows as it scans instead of ordering the file — and a
    // second ORDER BY term is exactly the sort of thing that could cost that.
    func plan(_ query: BoundSQL) async throws -> String {
        let cursor = try await session.openCursor(
            "EXPLAIN " + query.sql, params: query.params, renderAsText: false)
        var text = ""
        while let page = try await cursor.fetch(maxRows: 256) {
            text += page.cells.compactMap { $0 }.joined(separator: "\n")
        }
        await cursor.close()
        return text
    }

    let windowPlan = try await plan(SQLBuilder.windowed(tiebroken, limit: TableModel.pageSize))
    expect(windowPlan.contains("TOP_N"), "a tiebroken window still plans as Top-N")
    expect(!windowPlan.contains("ORDER_BY"), "with no separate full ordering left in the plan")
    expect(windowPlan.contains("t.flagged ASC"), "on the user's key")

    // And the same in the `OFFSET` form, which is what `loadEarlier()` issues.
    // Top-N handles an offset by keeping `limit + offset` rows, so the clause
    // survives; it is worth pinning because a plan that dropped to a full sort
    // here would only show up as a slow scroll on a file nobody tests with.
    let offsetPlan = try await plan(
        SQLBuilder.windowed(tiebroken, limit: TableModel.pageSize, offset: TableModel.pageSize))
    expect(offsetPlan.contains("TOP_N"), "and so does a tiebroken window read at an offset")
    expect(!offsetPlan.contains("ORDER_BY"), "which is the read a backward step makes")

    // It runs, and the grid gets the columns it had before, in the same order.
    let read = try await session.queryAll(
        SQLBuilder.windowed(tiebroken, limit: 5).sql, params: tiebroken.params, limit: 5)
    expectEqual(read.columns, ["id", "category", "score", "flagged", "day", "label"],
                "the tiebreaker does not arrive as a column of the result")

    let datasetRead = try await session.queryAll(
        SQLBuilder.windowed(dataset, limit: 5).sql, params: dataset.params, limit: 5)
    expect(!datasetRead.columns.contains("__duckparq_filename"),
           "nor does the file name on a dataset")
    expect(datasetRead.columns.contains("year") && datasetRead.columns.contains("region"),
           "and excluding it leaves the hive partition columns alone")
}

// What the tiebreaker is allowed to reach. It belongs to every query that
// produces rows — the grid's window, the pages either end of it, and the export
// — because those all have to agree about which rows they are talking about.
do {
    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "order-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "order-meta"),
        countSession: try DuckDBSession(engine: engine, label: "order-count"),
        filterSession: try DuckDBSession(engine: engine, label: "order-filter"),
        cache: PreviewCache()
    )
    model.open(.file(smallParquet))
    await settle(model)
    expect(model.currentQuery?.sql.contains("file_row_number") == false,
           "an unsorted view has no ORDER BY to make total, so it carries no tiebreaker")

    model.toggleSort(column: "flagged")
    await settle(model)
    expect(model.currentQuery?.sql.contains("file_row_number = true") == true,
           "a sorted view carries it")

    // Export. `limit` is the loaded row count — "write out what I am looking
    // at" — so an export ordering its ties differently from the grid would
    // silently write a different set of rows than the one on screen.
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-tiebreak.csv")
    try? FileManager.default.removeItem(at: destination)
    let copy = SQLBuilder.export(
        query: model.currentQuery!, to: destination, format: .csv, limit: model.rows.count)
    try await session.execute(copy.sql, params: copy.params)

    let written = try String(contentsOf: destination, encoding: .utf8)
        .split(separator: "\n").dropFirst()
        .map { String($0.split(separator: ",", maxSplits: 1)[0]) }
    let onScreen = model.rows.map { $0.cells[0] ?? "" }
    expectEqual(written.count, onScreen.count, "the export writes the loaded rows")
    expectEqual(written, onScreen, "and writes exactly the rows on screen, in that order")
    try? FileManager.default.removeItem(at: destination)

    // The editor. The text names a column the user cannot see, which is a fair
    // objection — but it is part of what decides the rows on screen, and text
    // that leaves it out describes a different page than the one it claims to.
    let editable = model.editableSQL!
    expect(editable.contains("file_row_number"), "the editable SQL says so rather than hiding it")
    let rerun = try await session.queryAll(
        "SELECT * FROM (\(editable)) LIMIT \(model.rows.count)", limit: model.rows.count)
    expectEqual(rerun.column("id").map { $0 ?? "" }, onScreen,
                "and running it gives back the grid, which is the point of offering it")

    model.clear()
}

// A source whose data already has a column called `file_row_number`.
//
// `read_parquet` refuses the option outright on one — it takes a bool, so there
// is no name to move it out of the way to, the way `filename` has. The grid
// therefore has to notice and go without, because the alternative is a file
// that cannot be sorted at all.
do {
    let clashing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("duckparq-selftest-file-row-number.parquet")
    try? FileManager.default.removeItem(at: clashing)
    try await session.execute(
        "COPY (SELECT i AS id, (i % 2) = 0 AS flagged, i AS file_row_number FROM range(20) t(i)) "
        + "TO $1 (FORMAT parquet)",
        params: [clashing.path])

    // First that the option really is refused, so what follows is guarding
    // against DuckDB's behaviour rather than against a guess about it.
    do {
        _ = try await session.queryAll(
            "SELECT * FROM read_parquet($1, file_row_number = true)",
            params: [clashing.path], limit: 1)
        expect(false, "reading such a file with the option on is expected to fail")
    } catch {
        expect(true, "read_parquet refuses file_row_number on a file that has that column")
    }

    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "clash-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "clash-meta"),
        countSession: try DuckDBSession(engine: engine, label: "clash-count"),
        filterSession: try DuckDBSession(engine: engine, label: "clash-filter"),
        cache: PreviewCache()
    )
    model.open(.file(clashing))
    await settle(model)
    expectEqual(model.errorMessage, String?.none, "the file opens")
    expectEqual(model.rows.count, 20, "with its rows")

    model.toggleSort(column: "flagged")
    await settle(model)
    expectEqual(model.errorMessage, String?.none,
                "and sorting it does not fail for want of a tiebreaker")
    expectEqual(model.rows.count, 20, "the sorted rows are still all there")
    expect(model.currentQuery?.sql.contains("file_row_number = true") == false,
           "because the tiebreaker is declined on a source that already has the column")
    expect(model.editableSQL?.contains("EXCLUDE") == false,
           "and the SQL the editor is offered does not mention one either")

    model.clear()
    try? FileManager.default.removeItem(at: clashing)
}

// MARK: - Paging integrity (no row shown twice, none skipped)

// Scrolling through a result must show every row exactly once. The row ids the
// grid carries cannot tell you whether it does: they are ordinals — `windowStart
// + index` — so a row served twice under two different offsets arrives as two
// different ids, and a walk that repeats half its rows still hands back
// `0..<3000` in perfect order. These checks therefore compare the *data* of a
// stable key column across the whole walk, which is the only thing that can tell
// a repeat from a legitimately different row.
//
// The seams that can go wrong are the ones where two adjacent pages come from
// two separate query executions: `loadEarlier()`'s OFFSET reads, the crossover
// in `fetchPage` where one page is counted forward and its neighbour counted
// backward with the sort inverted, and `loadMore()`'s re-run of the whole
// window at twice the size. Under a sort with ties none of those executions is
// answering a question that identifies a specific set of rows — which is why
// two of the three ways the grid pages are given a total order to answer
// against, and the third given no ORDER BY at all.

section("Paging integrity")

/// Every value of `keyColumn`, in view order, from a walk out of the last page
/// back to row 0 — what holding the scroll wheel up from the End key does.
///
/// Collected a page at a time as the walk goes, using `prependedRowCount` to
/// take exactly what each backward step spliced onto the front. Reading the
/// final `model.rows` instead would be no cheaper and would lose the seams.
@MainActor
func walkBackward(_ model: TableModel, keyColumn: String) async -> [String] {
    guard let index = model.columns.firstIndex(where: { $0.name == keyColumn }) else { return [] }
    func keys(_ rows: ArraySlice<TableModel.GridRow>) -> [String] {
        rows.map { $0.cells[index] ?? "<null>" }
    }

    model.jumpToEnd()
    await settle(model)
    var seen = keys(model.rows[...])

    // Bounded so a step that fails to move cannot spin: every step must take
    // the window strictly closer to row 0.
    while !model.reachedStart {
        let before = model.windowStart
        model.loadEarlier()
        await settle(model)
        guard model.windowStart < before, model.prependedRowCount > 0 else { break }
        seen = keys(model.rows.prefix(model.prependedRowCount)) + seen
    }
    return seen
}

/// How a walk differs from the rows the result actually holds.
func pagingDefects(walked: [String], expected: Set<String>) -> (repeats: Int, skipped: Int) {
    var counts: [String: Int] = [:]
    for key in walked { counts[key, default: 0] += 1 }
    let repeats = counts.values.reduce(0) { $0 + ($1 - 1) }
    let skipped = expected.subtracting(counts.keys).count
    return (repeats, skipped)
}

do {
    let model = TableModel(
        gridSession: try DuckDBSession(engine: engine, label: "paging-grid"),
        metaSession: try DuckDBSession(engine: engine, label: "paging-meta"),
        countSession: try DuckDBSession(engine: engine, label: "paging-count"),
        filterSession: try DuckDBSession(engine: engine, label: "paging-filter"),
        cache: PreviewCache()
    )

    // 1. A hive dataset in the sort it opens in. `defaultSort(for:)` orders it
    // by its top-level partition key alone, and a partition key is by nature
    // very low cardinality — 3000 rows over two `year` values here — so very
    // nearly every row ties with every other under that ORDER BY. `OFFSET n`
    // does not name a particular set of rows when the ties are that broad.
    model.open(.dataset(hiveDirectory))
    await settle(model)
    expectEqual(model.sort.map(\.column), ["year"], "the hive dataset opens on its partition key")
    expectEqual(model.totalRowCount, 3000, "over all 3000 rows")
    expect(model.pagesByFile, "so it pages by walking its files rather than by ORDER BY")

    let hiveWalk = await walkBackward(model, keyColumn: "id")
    let hiveExpected = Set((0..<3000).map(String.init))
    let hiveDefects = pagingDefects(walked: hiveWalk, expected: hiveExpected)
    expectEqual(hiveWalk.count, 3000, "the walk back visits as many rows as the dataset holds")
    expectEqual(hiveDefects.repeats, 0,
                "scrolling up through a hive dataset shows no row twice")
    expectEqual(hiveDefects.skipped, 0,
                "and skips none of them")

    // The file order is a refinement of the sort in the header, not a
    // departure from it: every row still sits inside its own partition's run,
    // so the walk is still ordered by `year` -- it just also settles which of
    // the rows tied on `year` come first, which is what the ORDER BY left open.
    let yearIndex = model.columns.firstIndex { $0.name == "year" }!
    let walkedYears = model.rows.map { $0.cells[yearIndex] ?? "" }
    expectEqual(walkedYears.count, 3000, "the whole dataset is loaded after the walk")
    expect(walkedYears == walkedYears.sorted(), "and is still ordered by the partition key")

    // Filters. Footer row counts say how many rows a file holds, not how many
    // a filter admits, so the index has to count per file before it can address
    // a row by offset -- and must still land on exactly the matching rows.
    //
    // `value < 137` is chosen so the counts come out uneven (138, 138, 138,
    // 136, 136, 136) and no page boundary lands on a file boundary. Unfiltered,
    // every fixture file holds exactly one page, so every read starts at row 0
    // of some file and the mid-file offset -- the part of the addressing with
    // any arithmetic in it -- never runs. Here the tail window starts 46 rows
    // into the third file.
    let verifier = try DuckDBSession(engine: engine, label: "paging-verify")
    let matching = try await verifier.queryAll(
        "SELECT id FROM read_parquet($1, hive_partitioning = true, union_by_name = true) "
        + "WHERE value < 137",
        params: [DataSource.dataset(hiveDirectory).readPath], limit: 5000)
    let matchingIDs = Set(matching.column("id").compactMap { $0 })
    expect(matchingIDs.count > TableModel.pageSize,
           "the filter leaves more than one page, so the walk has seams to get wrong")
    expect(matchingIDs.count % TableModel.pageSize != 0,
           "and does not divide evenly into pages, so a page must start mid-file")

    model.upsert(filter: Filter(
        column: model.column(named: "value")!, mode: .comparison(.lessThan, ["137"])))
    await settle(model)
    expectEqual(model.totalRowCount, matchingIDs.count, "the filter reaches DuckDB")
    expect(model.pagesByFile, "a filtered hive dataset still pages by file")

    let filteredWalk = await walkBackward(model, keyColumn: "id")
    let filteredDefects = pagingDefects(walked: filteredWalk, expected: matchingIDs)
    expectEqual(filteredWalk.count, matchingIDs.count,
                "the filtered walk visits as many rows as match")
    expectEqual(filteredDefects.repeats, 0, "a filtered hive walk shows no row twice")
    expectEqual(filteredDefects.skipped, 0, "and skips none of the matching rows")
    expectEqual(Set(filteredWalk), matchingIDs, "and visits exactly the rows the filter admits")

    model.clearFilters()
    await settle(model)

    // A user sort takes the file order away, because it says nothing about a
    // column that is not the partition key. The dataset goes back to being
    // paged by ORDER BY, and has to be correct there too — see 2b.
    model.toggleSort(column: "value")
    await settle(model)
    expect(!model.pagesByFile, "sorting by a data column leaves the file order behind")
    model.open(.dataset(hiveDirectory))
    await settle(model)
    expect(model.pagesByFile, "and reopening the dataset returns to it")

    // Neither a single file nor a plain folder of parquet files has a
    // partition order to walk.
    model.open(.file(smallParquet))
    await settle(model)
    expect(!model.pagesByFile, "a single file has no partitions to page by")
    model.open(.dataset(fixtures))
    await settle(model)
    expect(!model.pagesByFile, "nor does a plain folder of parquet files")

    // 2. The same tie problem without hive partitioning: a single file sorted
    // by a low-cardinality column. `flagged` is a boolean, so the result is two
    // tie groups, and the seam between the page counted forward and the page
    // counted backward falls inside one of them. This used to hand back 166
    // rows twice and never show 166 others, deterministically, every run.
    //
    // The hive path above sidesteps ties by not sorting at all, which an
    // ordinary file cannot do — it has no partition layout to page by. What
    // fixes it here is a total order: `read_parquet`'s `file_row_number`
    // appended to the ORDER BY, which needs no unique column in the data and
    // still plans as a Top-N (asserted in "Total order").
    model.open(.file(smallParquet))
    await settle(model)
    model.toggleSort(column: "flagged")
    await settle(model)
    expectEqual(model.sortDirection(for: "flagged"), .ascending, "sorted by a two-valued column")

    let flaggedWalk = await walkBackward(model, keyColumn: "id")
    let smallExpected = Set((0..<1000).map(String.init))
    let flaggedDefects = pagingDefects(walked: flaggedWalk, expected: smallExpected)
    expectEqual(flaggedWalk.count, 1000, "the walk visits as many rows as the file holds")
    expectEqual(flaggedDefects.repeats, 0,
                "scrolling up a file sorted by a boolean shows no row twice")
    expectEqual(flaggedDefects.skipped, 0, "and skips none of them")

    // The tiebreaker refines the user's sort rather than displacing it: the
    // walk is still in `flagged` order, it just also settles which of the rows
    // sharing a value come first.
    let flaggedIndex = model.columns.firstIndex { $0.name == "flagged" }!
    let walkedFlags = model.rows.map { $0.cells[flaggedIndex] ?? "" }
    expectEqual(walkedFlags.count, 1000, "the whole file is loaded after the walk")
    expect(walkedFlags == walkedFlags.sorted(), "and is still ordered by the column asked for")

    // A four-valued column, where the forward/backward crossover lands on a
    // group boundary rather than inside one.
    model.open(.file(smallParquet))
    await settle(model)
    model.toggleSort(column: "category")
    await settle(model)
    let categoryWalk = await walkBackward(model, keyColumn: "id")
    let categoryDefects = pagingDefects(walked: categoryWalk, expected: smallExpected)
    expectEqual(categoryDefects.repeats, 0, "nor does a four-valued sort repeat a row")
    expectEqual(categoryDefects.skipped, 0, "nor skip one")

    // The same seam with a WHERE in front of it, so the tiebreaker is asked to
    // order a filtered result rather than a whole file. 700 matching rows puts
    // the tail window at offset 200 and leaves the crossover between the page
    // counted backward and the page counted forward inside a tie group.
    model.open(.file(smallParquet))
    await settle(model)
    model.toggleSort(column: "category")
    await settle(model)
    model.upsert(filter: Filter(
        column: model.column(named: "score")!, mode: .comparison(.lessThan, ["700"])))
    await settle(model)
    expectEqual(model.totalRowCount, 700, "the filter reaches DuckDB")

    let scoredWalk = await walkBackward(model, keyColumn: "id")
    let scoredExpected = Set(try await verifier.queryAll(
        "SELECT id FROM read_parquet($1) WHERE score < 700",
        params: [smallParquet.path], limit: 1000).column("id").compactMap { $0 })
    let scoredDefects = pagingDefects(walked: scoredWalk, expected: scoredExpected)
    expectEqual(scoredWalk.count, 700, "the filtered walk visits as many rows as match")
    expectEqual(scoredDefects.repeats, 0, "a filtered, sorted walk shows no row twice")
    expectEqual(scoredDefects.skipped, 0, "and skips none of the matching rows")
    expectEqual(Set(scoredWalk), scoredExpected, "and visits exactly the rows the filter admits")

    // 2b. A multi-file source under a user sort — the case a single file cannot
    // reach. `file_row_number` counts within one file, so it repeats once per
    // file and is not a row's name on its own; the filename has to go in front
    // of it. Six files here, `region` taking three values across all 3000 rows,
    // so the ties are as broad as they get and every page boundary but the
    // first falls inside one.
    model.open(.dataset(hiveDirectory))
    await settle(model)
    model.toggleSort(column: "region")
    await settle(model)
    expect(!model.pagesByFile, "a sorted dataset is paged by ORDER BY, not by file")
    expectEqual(model.totalRowCount, 3000, "over all 3000 rows")

    let regionWalk = await walkBackward(model, keyColumn: "id")
    let regionDefects = pagingDefects(walked: regionWalk, expected: hiveExpected)
    expectEqual(regionWalk.count, 3000, "the walk visits as many rows as the dataset holds")
    expectEqual(regionDefects.repeats, 0,
                "scrolling up a sorted dataset of six files shows no row twice")
    expectEqual(regionDefects.skipped, 0, "and skips none of them")

    let regionIndex = model.columns.firstIndex { $0.name == "region" }!
    let walkedRegions = model.rows.map { $0.cells[regionIndex] ?? "" }
    expect(walkedRegions == walkedRegions.sorted(), "and is still ordered by region")

    // 3. An unsorted result, where `pageAddress` always counts forward because
    // there is no order to run backward. Two `LIMIT`/`OFFSET` reads of a
    // parquet scan are still two executions, and DuckDB may scan in parallel —
    // so this asks whether a scan's row order is stable enough across separate
    // queries for the offsets to line up.
    model.open(.file(smallParquet))
    await settle(model)
    expect(model.sort.isEmpty, "a plain file opens unsorted")
    let unsortedWalk = await walkBackward(model, keyColumn: "id")
    let unsortedDefects = pagingDefects(walked: unsortedWalk, expected: smallExpected)
    expectEqual(unsortedDefects.repeats, 0, "an unsorted walk shows no row twice")
    expectEqual(unsortedDefects.skipped, 0, "and skips none")
    expectEqual(unsortedWalk, (0..<1000).map(String.init),
                "an unsorted scan pages in the file's own row order")

    // A multi-file dataset unsorted, where the scan has several files to read
    // and more room to reorder them between one query and the next.
    model.open(.dataset(hiveDirectory))
    await settle(model)
    model.clearSort()
    await settle(model)
    expect(model.sort.isEmpty, "the dataset's opening sort can be cleared")
    let datasetWalk = await walkBackward(model, keyColumn: "id")
    let datasetDefects = pagingDefects(walked: datasetWalk, expected: hiveExpected)
    expectEqual(datasetDefects.repeats, 0, "an unsorted walk over many files shows no row twice")
    expectEqual(datasetDefects.skipped, 0, "and skips none")

    // 4. Forward widening under a tied sort. `performInitialLoad` re-runs the
    // whole query as one `LIMIT windowSize` from row 0 rather than appending,
    // and its comment claims that is what keeps a widened window free of the
    // duplicates OFFSET paging produces. Within a single window that holds —
    // one query cannot return a row twice. The question this asks is the other
    // half of it: whether the rows the reader has *already* seen are still
    // there after the window grows, or whether widening quietly swaps them for
    // different members of the same tie group.
    model.open(.dataset(hiveDirectory))
    await settle(model)
    expectEqual(model.sort.map(\.column), ["year"], "back to the tied opening sort")
    let idColumn = model.columns.firstIndex { $0.name == "id" }!
    let beforeWidening = Set(model.rows.compactMap { $0.cells[idColumn] })
    expectEqual(beforeWidening.count, TableModel.pageSize, "a full opening window to widen from")

    model.loadMore()
    await settle(model)
    expectEqual(model.windowSize, TableModel.pageSize * 2, "the window doubled")
    let afterWidening = Set(model.rows.compactMap { $0.cells[idColumn] })
    let vanished = beforeWidening.subtracting(afterWidening)
    expectEqual(vanished.count, 0,
                "widening the window keeps the rows already read rather than "
                + "replacing them with other rows of the same tie group")

    // The same question on the ORDER BY path, which is where widening was
    // actually measured losing rows — all 500 replaced in two runs out of five.
    // A dataset under a user sort, so the file walk is not what is answering.
    //
    // Asked twice over: no row already read has gone, and the rows already read
    // are still in the same places. The second is the stronger claim, and the
    // one a reader would notice breaking — a window that keeps every row but
    // shuffles the tied ones has still moved the text under their eye.
    @MainActor
    func keys(_ model: TableModel, _ column: String) -> [String] {
        guard let index = model.columns.firstIndex(where: { $0.name == column }) else { return [] }
        return model.rows.map { $0.cells[index] ?? "<null>" }
    }

    model.open(.dataset(hiveDirectory))
    await settle(model)
    model.toggleSort(column: "region")
    await settle(model)
    expect(!model.pagesByFile, "a sorted dataset widens through the ORDER BY path")
    let beforeSortedWidening = keys(model, "id")
    expectEqual(beforeSortedWidening.count, TableModel.pageSize, "a full window to widen from")

    model.loadMore()
    await settle(model)
    expectEqual(model.windowSize, TableModel.pageSize * 2, "the window doubled")
    let afterSortedWidening = keys(model, "id")
    expectEqual(afterSortedWidening.count, TableModel.pageSize * 2, "and came back full")
    expectEqual(Set(beforeSortedWidening).subtracting(afterSortedWidening).count, 0,
                "widening a sorted dataset loses none of the rows already read")
    expectEqual(Array(afterSortedWidening.prefix(TableModel.pageSize)), beforeSortedWidening,
                "and leaves them exactly where they were")

    // And on a single file, where the tiebreaker is the row number alone.
    model.open(.file(smallParquet))
    await settle(model)
    model.toggleSort(column: "flagged")
    await settle(model)
    let beforeFileWidening = keys(model, "id")
    expectEqual(beforeFileWidening.count, TableModel.pageSize, "half the file to widen from")

    model.loadMore()
    await settle(model)
    let afterFileWidening = keys(model, "id")
    expectEqual(afterFileWidening.count, 1000, "widening to the whole file")
    expectEqual(Array(afterFileWidening.prefix(TableModel.pageSize)), beforeFileWidening,
                "keeps the first page exactly as it was rather than re-breaking its ties")

    // 5. The remaining seam is the one where the two directions would meet:
    // a window that has been walked backward, then widened forward. It is not
    // reachable, and that is worth pinning down rather than inferring — the
    // only thing that moves `windowStart` off zero is `jumpToEnd()`, which
    // anchors on the last row and so leaves `reachedEnd` set, and `loadMore()`
    // declines to widen a window that already reaches the end. So a backward
    // walk never has a forward widening spliced onto it, and the seam that
    // would mix an OFFSET page with a re-run `LIMIT` window cannot form.
    model.open(.file(smallParquet))
    await settle(model)
    model.toggleSort(column: "flagged")
    await settle(model)
    model.jumpToEnd()
    await settle(model)
    expect(model.reachedEnd, "a tail window is by construction at the end")
    model.loadEarlier()
    await settle(model)
    expectEqual(model.windowStart, 0, "one step back from the tail of 1000 rows reaches row 0")
    expect(model.reachedEnd, "and the tail is still the end")

    let generationBeforeWidening = model.rowsGeneration
    let rowsBeforeWidening = model.rows.count
    model.loadMore()
    await settle(model)
    expectEqual(model.rowsGeneration, generationBeforeWidening,
                "widening forward is declined on a window that already reaches the end")
    expectEqual(model.rows.count, rowsBeforeWidening, "so the walked-back rows are left alone")

    // `continuePastCap()` picks its direction from `windowStart`, and the two
    // cases do not overlap: `loadEarlier()` refuses at row 0, so it is never
    // the call that raised the cap there.
    expectEqual(model.windowStart, 0, "at row 0 after the walk back")
    expect(!model.hitRowCap, "a thousand rows is nowhere near the cap")

    model.clear()
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

    // End on a 10M-row file must land on the real last page without reading
    // the 10M rows in front of it -- the whole reason `jumpToEnd()` exists
    // rather than scrolling there by widening the window until it covers the
    // file. Explicitly unsorted: the cancelled sort above left `key` behind as
    // the active sort, and jumping to the end of that would correctly land on
    // the last row in key order rather than the file's physical last row.
    model.clearSort()
    await settle(model)
    let bigIdIndex = model.columns.firstIndex { $0.name == "id" }!
    let endAt = Date()
    model.jumpToEnd()
    await settle(model)
    let endElapsed = Date().timeIntervalSince(endAt)
    expectEqual(model.rows.count, TableModel.pageSize, "the tail window is one page of a 10M-row file")
    expectEqual(model.windowStart, 10_000_000 - TableModel.pageSize,
                "the tail window starts one page before the file's last row")
    expect(model.reachedEnd, "the tail window reaches the file's actual last row")
    expectEqual(model.rows.last?.cells[bigIdIndex], "9999999", "the last row is the file's actual last row")
    expect(endElapsed < 5, "jumping to the end of a 10M-row file is fast (took \(String(format: "%.2f", endElapsed))s)")
    print("  jump to end: \(String(format: "%.2f", endElapsed))s")

    // Scrolling up a step from there pages in one more chunk, not the other
    // 9,999,500 rows in front of it.
    let earlierAt = Date()
    model.loadEarlier()
    await settle(model)
    let earlierElapsed = Date().timeIntervalSince(earlierAt)
    expectEqual(model.rows.count, TableModel.pageSize * 2, "one step back loads one more page")
    expectEqual(model.windowStart, 10_000_000 - TableModel.pageSize * 2,
                "the window's start moves back by exactly one page")
    expect(earlierElapsed < 5,
           "loading one earlier page stays cheap (took \(String(format: "%.2f", earlierElapsed))s)")
    print("  load one earlier page: \(String(format: "%.2f", earlierElapsed))s")

    // The end of a *sorted* 10M-row result. This is the case that inverting
    // the ORDER BY exists for: reaching it with OFFSET means ordering all 10M
    // rows and discarding all but the last page, because the rows a Top-N
    // keeps are precisely the ones this wants thrown away. Inverted it is a
    // Top-N like any other, so it must land in about the time a sorted first
    // page takes rather than the time a full sort takes.
    model.toggleSort(column: "measure")
    await settle(model)
    let sortedEndAt = Date()
    model.jumpToEnd()
    await settle(model)
    let sortedEndElapsed = Date().timeIntervalSince(sortedEndAt)
    expectEqual(model.rows.count, TableModel.pageSize, "the sorted tail is one page")
    expectEqual(model.windowStart, 10_000_000 - TableModel.pageSize, "anchored at the end of the sort")
    let tailMeasures = model.rows.compactMap { $0.cells[measureIndex].flatMap(Double.init) }
    expectEqual(tailMeasures.count, TableModel.pageSize, "every tail row carries a measure")
    expect(tailMeasures == tailMeasures.sorted(),
           "the inverted read is turned back over, so the page reads ascending like the sort")

    // Cross-check against DuckDB's own answer for the largest value, so a
    // page that is internally consistent but off the end cannot pass.
    let tailCheck = try await verifier.queryAll(
        "SELECT measure FROM read_parquet($1) ORDER BY measure DESC LIMIT 1",
        params: [bigParquet.path], limit: 1)
    expectEqual(model.rows.last?.cells[measureIndex], tailCheck[0, 0],
                "the last row of the sorted tail is DuckDB's own maximum")
    expect(sortedEndElapsed < 5,
           "the end of a sorted 10M-row result is a Top-N, not a full sort "
           + "(took \(String(format: "%.2f", sortedEndElapsed))s)")
    print("  jump to end, sorted: \(String(format: "%.2f", sortedEndElapsed))s")
    model.clearSort()
    await settle(model)
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
