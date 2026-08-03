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

**Every query carries a `LIMIT`.** The grid asks for a window — 500 rows to
begin with — and that clause is the difference between browsing a large file and
waiting for one. DuckDB plans `ORDER BY … LIMIT 500` as a **Top-N**: it keeps 500
rows as it scans, instead of ordering three billion of them and discarding all
but the first screenful. Without the limit, the first row cannot appear until the
entire sort has finished. The suite asserts the plan, not just the behaviour,
because the whole benefit rests on DuckDB pushing the limit through the wrapper.

The window belongs to the viewport, not to the query: `currentQuery` stays
unbounded, so export still means every matching row, the row count still counts
every matching row, and the SQL offered in the editor carries no limit you did
not write.

**Scrolling widens the window and re-runs**, doubling it each time. Two
alternatives were considered and rejected. Keeping one long-lived cursor and
reading further along it is what this used to do; it makes paging free but costs
a *full sort before the first row*, which is the problem. `LIMIT`/`OFFSET` per
page transfers less, but each page is a separate execution, and DuckDB's sort is
not stable — with ties, a row can land on two pages or on none. Doubling avoids
both: every rendered view is one coherent result set, and reaching row N takes a
logarithmic number of re-runs rather than one per page. It is the wrong trade for
reading a million rows in order, which is what the export button is for.

Changing sort or filters interrupts the running query — but the rows already on
screen stay put until the replacements arrive. Re-sorting shows the same rows in
a different order, so blanking the grid while the sort runs would state something
untrue about the data.

**Preview, schema and row count are three separate questions**, asked at once.
The first page does not wait behind a `DESCRIBE` of a thousand-file dataset, and
a `count(*)` over the whole thing does not hold up either. Each renders when it
can; the status bar says which are still running, and Cancel interrupts them.

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
SELECT, so the restriction costs a viewer nothing. `EXPLAIN` is admitted too, and
is the one statement that has to be run verbatim: both the row window and the
`COLUMNS(*)::VARCHAR` wrap are a `SELECT` over the statement, and you cannot
select from an `EXPLAIN`. Its output is already text, so it needs neither — and
the exemption keys off the kind DuckDB's parser reported, never off the text.
Meanwhile `COPY … TO`, `ATTACH`,
`INSTALL`, `CREATE`, `DROP` and the rest are refused. Because the check is a
parse and not a pattern match, `SELECT 1; DROP VIEW t` is seen as two
statements, one of which is a write — which is what makes opening a `.sql` file
someone else wrote safe.

**Opening the same file twice is free.** The first page, schema and row count of
an unfiltered, unsorted view are remembered against a fingerprint of the source —
file count, total size and newest modification time, which is what `stat` can
answer cheaply. Hashing the bytes to avoid reading them would defeat the point.
That misses a rewrite which preserved both size and timestamp, so **Clear Cache**
exists, and the cache is never consulted for a filtered, sorted or SQL result:
those are answers you are actively composing, where a remembered one would be
indistinguishable from a fresh one and wrong in a way you could not see. A cache
hit costs no query at all; scrolling past the remembered window reads for real.
The inspector's answers are cached against the same fingerprint, which matters
most for the per-column row-group statistics — `parquet_metadata` is O(row groups
× columns) and opens every footer in the dataset, the most expensive question the
app asks. Above a few thousand row groups it is not asked unattended at all: the
cheap file summary reports how many there are, and the panel offers to read them.

### Sessions

Seven independent DuckDB sessions — grid, schema, row count, filter probe,
inspector, SQL editor, export.

**A session is a serial queue**, so "its own session" is the only thing that
actually makes two concerns concurrent; running them as two Swift tasks against
one session just queues them. That was a real bug: the schema lookup, the
`count(*)` and the inspector's metadata all shared one session, so opening the
inspector on a large dataset waited behind a count of every row in it. They are
split accordingly, and the split follows the cost — counting and inspecting are
the two that can run for seconds.

Each cursor also gets its own connection, because DuckDB permits only one active
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
| ⌘. | Cancel the running query |
| ⌘C | Copy the selected row as TSV |
| ⌘S | Save the editor's query as a `.sql` file |
| ⇧⌘O | Open a saved `.sql` query |
| ⇧⌘F | Re-indent the editor's SQL |

Folders holding parquet files — or `key=value` hive partitions — get a
**dataset** badge and open as a single table. Right-click one to copy its path,
or the `read_parquet(…)` call for it. Hive partitions are *not* listed as
folders: `year=2024/region=eu/` is a column of one table, not somewhere to browse
into, so the layout is recognised and the folder offered whole.

Sidebar folders collapse and expand individually, and the two toolbar buttons do
it wholesale. Expand All is the one place the sidebar reads the whole tree rather
than a level at a time, so it is bounded and runs off the main thread.

The grid scrolls on both axes in one scroll view, so the vertical scrollbar sits
against the window rather than against the last column, and the header pins to
the top while still scrolling sideways with the columns it labels.

The status bar counts up while a query runs and keeps the final figure
afterwards, with **Cancel** beside it — that interrupts the query inside DuckDB
rather than abandoning it, so a cancelled sort of a large file actually stops.

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

**Save** and **Open** are one click each. Saved queries default to
`~/Library/Application Support/DuckParq/Queries` and the ones already there are
behind the small chevron, but they are ordinary files and can live anywhere. A
loaded file is put in the editor and *not* run — you see it before it executes,
and when you do run it, it goes through the read-only check above.

**Format** re-indents the query, and the checkbox beside Save runs it on the way
to the file. It moves whitespace and nothing else: the formatter re-emits the
exact text of every token the tokenizer produced, in order, so no literal is
rewritten and no clause is regenerated from an understanding of SQL it does not
have. The suite checks that by re-tokenizing the output of every sample and
requiring an identical token stream, and by running a query before and after
formatting and comparing the rows.

Applying a filter also updates the editor, as long as it is still showing the
view's query — anything typed is left alone.

Filter popovers pick their controls from **how many distinct values a column
actually has**, asked *when the popover opens* — probing every column on file
select would mean a scan per column, which is what this app exists to avoid.

Two queries, in cost order, and the answer is exact either way. First a bounded
read of the head: more than 50 distinct values in *any* subset proves more than
50 in the column, so this can rule a column out cheaply, and can never wrongly
rule one in. Whatever survives gets the real question — `SELECT DISTINCT` over
the whole column. `DISTINCT` is a blocking hash aggregate, so it does read the
column; it is only ever reached for columns that look enumerable, where the hash
table stays small and parquet's dictionary encoding makes the scan cheap. Asking
for one more value than the cap is what separates "too many to list" from
"exactly the cap". The result is cached against the source's fingerprint, so a
popover is answered once per file version.

The values in the list are therefore the column's, complete, and the popover says
nothing to qualify them. An earlier version showed the head sample's values
directly, labelled "from the first 200,000 rows" — which on a column whose
leading rows are all NULL, as flag columns in real datasets very often are,
showed an empty list and a caveat in place of an answer.

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

The formatter is tested against its own invariant rather than against expected
output: format a sample, re-tokenize it, and require the same token stream —
which catches a split `<=`, a mangled literal, or a dropped clause. It is also
checked for idempotence, and one query is run before and after formatting with
every cell compared.

The cache is tested against a real rewrite: write a parquet file, fingerprint it,
write different contents to the same path, and require a different fingerprint.
The `TableModel` half checks that a second open is served from memory and that
scrolling past the remembered window continues *after* those rows rather than
repeating them.

The row window is tested against DuckDB's own plan, not just its output: a sorted
window has to come out as `TOP_N` with no surviving `ORDER_BY`, because the value
of the clause is entirely in the optimiser pushing it through the wrapper. Every
read-only statement form is also run through the wrapper, which is how `EXPLAIN`
being the one that cannot be is a checked fact rather than a remembered one.

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
