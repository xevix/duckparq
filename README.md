# DuckParq

A native macOS parquet viewer for glancing at files quickly: point it at a
folder, click through parquet files in the sidebar, see rows immediately. Sort,
filter, or drop into SQL when you need to. DuckDB does the querying.

Not intended for the App Store — the app is unsandboxed and ad-hoc signed.

## Requirements

macOS 15+, Apple silicon, and a Swift toolchain. **Xcode is not required** —
Command Line Tools are enough, which is why the app is a SwiftPM executable
assembled into a `.app` by a script rather than an Xcode project.

The `duckdb` CLI is needed only to generate test fixtures, never at runtime.

## Build

```bash
make smoke   # fetch + verify DuckDB, then prove the static link works
make app     # build DuckParq.app
make run     # build and launch
make install # copy to /Applications
make test    # run the self-test suite
```

`make smoke` is worth running first on a fresh checkout: it downloads the pinned
DuckDB static libraries, verifies their SHA256, and runs a real
`SELECT * FROM read_parquet(...)` through the C bridge. If static extension
registration ever breaks, it fails there in seconds instead of at runtime.

## How it works

**DuckDB is vendored and statically linked.** `scripts/fetch-duckdb.sh` pulls a
pinned, checksum-verified `static-libs-osx-arm64.zip` (v1.5.5) into `Vendor/`.
The result is a single self-contained binary — `otool -L` on the app shows no
`libduckdb` at all, so it keeps working regardless of what Homebrew does.

That bundle ships only the C header, so `Sources/CDuckParq` bridges over
DuckDB's **C API**. It loses nothing: `duckdb_interrupt` gives real query
cancellation and `duckdb_pending_prepared_streaming` + `duckdb_fetch_chunk` give
streaming cursors.

**Everything is pushed down to DuckDB.** Sorting is `ORDER BY`, filtering is
`WHERE`, and the app contains no client-side comparator. This is a correctness
requirement, not an optimization: the grid holds a *window* into a result, so
sorting the loaded rows would reorder a fragment and present it as the file's
order.

**Rows stream.** One cursor stays open per (file, filters, sort); scrolling
pulls the next page from the same stream. Paging never re-runs the query, so a
sort is paid for once rather than once per page as `LIMIT/OFFSET` would.
Changing sort or filters interrupts the running query and opens a new cursor.

**Cells arrive as text.** Queries are wrapped as
`SELECT COLUMNS(*)::VARCHAR FROM (<query>)`, so DuckDB renders every type —
DECIMAL, HUGEINT, TIMESTAMPTZ, LIST, STRUCT, MAP, ENUM, and BLOB (escaped, always
valid UTF-8). Column *types* come separately from `DESCRIBE`, and drive
alignment and which filter widgets appear.

**No user value is ever interpolated into SQL.** Paths and filter operands are
bound as `$n` parameters and cast at the comparison site, where the column's
real type is known. The one exception is text written *for* the user — the
query shown in the editor, the `read_parquet(…)` you can copy — which is display
output that re-enters through the parser like anything else you might type.

**SQL from the editor is read-only.** Every statement is classified by DuckDB's
own parser before it runs; only a single `SELECT` or `EXPLAIN` is accepted.
`DESCRIBE`, `SUMMARIZE`, `SHOW`, `WITH`, `VALUES` and bare `FROM t` all parse as
SELECT, so the restriction costs a viewer nothing, while `COPY … TO`, `ATTACH`,
`INSTALL`, `CREATE`, `DROP` and the rest are refused. Because the check is a
parse and not a pattern match, `SELECT 1; DROP VIEW t` is seen as two
statements, one of which is a write — which is what makes opening a `.sql` file
someone else wrote safe.

### Sessions

Four independent DuckDB sessions — grid, metadata, SQL editor, export — so a
slow sort can't delay a schema lookup and cancelling one never disturbs another.
Each cursor gets its own connection, because DuckDB permits only one active
streaming result per connection.

## Using it

| | |
| --- | --- |
| ⌘O | Add a folder to the sidebar |
| Click a column header | Sort ascending → descending → unsorted |
| Shift-click a header | Add a secondary sort key |
| Right-click a header | Filter that column |
| ⇧⌘E | Show/hide the SQL editor |
| ⌥⌘I | Show/hide schema & file metadata |
| ⌘R | Re-run the current query |
| ⌘C | Copy the selected row as TSV |
| ⌘S | Save the editor's query as a `.sql` file |
| ⇧⌘O | Open a saved `.sql` query |

Folders holding parquet files — or `key=value` hive partitions — get a
**dataset** badge and open as a single table. Right-click one to copy its path,
or the `read_parquet(…)` call for it.

Opening the SQL editor over a selected file fills it with the query driving the
grid — source, filters and sort, with the path written out — so you start from
what you are already looking at instead of a blank box. Editing it is the point;
**View SQL** puts the view's query back. Your own text is never overwritten by
this, only an untouched seed. The selection is also available as `t`, so
`SELECT * FROM t WHERE x > 1` works. Filter chips are disabled on SQL results;
edit the query instead.

The editor is syntax highlighted in **the DuckDB CLI's own colours** — not an
approximation of them. The palette was captured from `duckdb` v1.5.5, the
version vendored here, by driving it under a pty and reading the escape
sequences it emits while highlighting a line; the suite replays those captures
and requires DuckParq to colour every character the same way. Keywords come
from the engine's `duckdb_keywords()` rather than a hardcoded list, so the
highlighter and the parser agree by construction — which is why `count` and
`read_parquet` stay uncoloured, exactly as in the CLI. DuckDB ships separate
dark and light palettes and picks between them by asking the terminal for its
background colour; here the window's appearance answers the same question.

**Queries ▸ Save Query…** writes the editor to a `.sql` file, and **Open
Query…** loads one back. Saved queries default to
`~/Library/Application Support/DuckParq/Queries` and are listed in the same
menu, but they are ordinary files and can live anywhere. A loaded file is put in
the editor and *not* run — you see it before it executes, and when you do run
it, it goes through the read-only check above.

Filter popovers pick their controls by sampling a column's distinct values *when
the popover opens* — probing every column on file select would mean a scan per
column, which is what this app exists to avoid. Low cardinality gets a
multi-select list; anything else gets comparison operators. The sample reads the
first 200,000 rows, and the popover says so.

## Layout

```
Sources/CDuckParq/     C bridge over DuckDB's C API
Sources/DuckParqCore/  Engine (sessions, cursors, SQL building) + models
Sources/DuckParq/      SwiftUI app
Sources/DuckParqSelfTest/  Test suite (see below)
scripts/               fetch-duckdb.sh, smoke.c, make-fixtures.sh, make-app.sh
```

## Tests

A Command Line Tools-only toolchain ships neither XCTest nor swift-testing, so
the suite is a plain executable run by `make test` rather than `swift test`.

It covers SQL generation and quoting, filter compilation, type classification,
a bridge round-trip over every DuckDB type, hive datasets, error paths, query
cancellation, concurrent cursors, export, and the `TableModel` logic the UI
drives (sort cycling, paging, filters, SQL mode, error recovery).

The read-only policy is tested from both ends: reads that must be allowed
(including `DESCRIBE`, `SUMMARIZE`, `SHOW`), writes that must be refused, and a
write chained behind a `SELECT` — after which the suite checks the view the
`DROP` targeted is still there and that a refused `COPY` wrote nothing to disk.
The editor's SQL is checked by running it: the text shown to the user and the
bound query the grid runs must return identical rows.

`BIG=1 make fixtures` adds a 10M-row file, which enables a scale section
verifying that a large file still previews instantly and that sorting is really
pushed down — it cross-checks the grid's first sorted row against DuckDB's own
`ORDER BY`.
