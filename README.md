# DuckParq

[![CI](https://github.com/xevix/duckparq/actions/workflows/ci.yml/badge.svg)](https://github.com/xevix/duckparq/actions/workflows/ci.yml)

A native macOS parquet viewer for glancing at files quickly: point it at a
folder, click through parquet files in the sidebar, see rows immediately. Sort,
filter, or drop into SQL when you need to. DuckDB does the querying.

This project is not affiliated in any way with DuckDB, DuckLabs etc. It is an independent project.

![DuckParq showing a hive-partitioned dataset of 3.1 billion rows](docs/screenshot.png)

## Build and run

```bash
make run
```

You need **macOS 15 or later on Apple silicon** and a **Swift 6 toolchain**.
Xcode is not required — Command Line Tools are enough (`xcode-select
--install`)

## Adding a folder

**File ▸ Add Folder…** (⌘O), the **+** in the sidebar, or a folder dragged onto
the window. The folder joins the sidebar and stays there between launches, open
to whatever you last had open inside it — folders and datasets you expanded are
still expanded next launch, and a tree you collapsed stays collapsed. Folders
deleted or removed from the sidebar in the meantime are quietly forgotten.

A folder in the sidebar is a view of a directory rather than a photograph of it
taken when it was added. DuckParq watches every added folder, so a file written
by a job running alongside it, a partition landing in a dataset, or a rename in
Finder shows up on its own — including the *dataset* badge, which can appear or
disappear as the files under a folder start or stop agreeing on a schema.

The grid is deliberately left alone. What a folder holds is one question;
re-running a query under someone reading its results is another, and **View ▸
Refresh** (⌘R) is where that decision stays.

## Opening a single file

Three ways in, all doing the same thing:

- **File ▸ Open File…** (⌥⌘O).
- **Drag a file onto the window.** Anywhere in it — the whole window is the
  target. Drag a *folder* instead and it joins the sidebar, exactly as **Add
  Folder…** puts it there. Anything else is ignored.
- **Open it from Finder**, once the app is installed:

```bash
make install
```

That puts the app in `/Applications` and registers it as a handler for
`.parquet`, `.pq` and `.parq`, so Finder lists DuckParq under *Open With*,
offers it in *Get Info ▸ Open with*, and accepts a file dropped on its Dock
icon.

However it arrives, the file opens in the grid; where its row appears depends
on whether the sidebar can already reach it:

- **Inside a folder you added** — the folders down to it are expanded and the
  sidebar scrolls to the file, however deep it is.
- **Anywhere else** — it goes to **Recently Opened** at the top of the sidebar,
  and its folder is *not* added. Opening one file should not drag a Downloads
  directory into the sidebar. Right-click the row for **Add Containing
  Folder**, which moves it into the tree, or **Reveal in Finder**.

DuckParq does not take the association away from whatever already holds it.
To make it the one Finder uses on a double-click, set it in *Get Info ▸ Open
with* and press **Change All…**

## Seeing the queries

DuckParq turns what you click into SQL, and it will show you the SQL. Set
`DUCKPARQ_SQL` to a file and launch it:

```bash
DUCKPARQ_SQL=~/duckparq.sql.log open /Applications/DuckParq.app
```

Every statement is logged as it is issued, and again when it finishes with the
rows it produced and how long it took:

```
[sql #135 big-grid] SELECT * FROM (SELECT * FROM read_parquet('…/big.parquet') AS t ORDER BY t."measure" DESC) LIMIT 500
[sql #135 big-grid] → 500 rows in 0.023s
```

Values are substituted rather than left as `$1`, so a line can be pasted
straight into the `duckdb` CLI and run as it stands — which is usually the
quickest way to answer whether a query is doing what you expected. The number
pairs the two lines and the label names the session, so a log stays readable
while four of them query at once.

`DUCKPARQ_SQL=1` writes to stderr instead, which is what you want when running
the binary from a terminal rather than launching the bundle. Unset, nothing is
logged.

One caveat worth knowing before you send a log to anyone: substituted values
mean it records the paths you opened and the operands of any filter you
applied. It is a record of what you looked at.

There is a second trace, `DUCKPARQ_TRACE=1`, which prints grid geometry and the
scrolling behind it — for layout questions a screenshot cannot answer.

## License

DuckParq is [MIT licensed](LICENSE).

The app statically links DuckDB, which is MIT licensed as well.
