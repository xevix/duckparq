# DuckParq

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

## License

DuckParq is [MIT licensed](LICENSE).

The app statically links DuckDB, which is MIT licensed too, and through it a
set of compression, parsing and Unicode libraries — all permissive: MIT,
BSD-2/3-Clause, Apache-2.0, Boost, zlib, Unicode. Nothing in the binary is
copyleft, so shipping a build under MIT is straightforward: the only obligation
is to carry the notices, which
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) collects in full and
`make app` copies into `DuckParq.app/Contents/Resources/`.

Two of those libraries offer a copyleft alternative — Mbed TLS is Apache-2.0 or
GPL-2.0-or-later, Zstandard is BSD-3-Clause or GPL-2.0 — and both leave the
choice to the user, so they are taken under the permissive option.

Nothing here interacts badly with a macOS app. The App Store's terms are what
GPL code collides with, and there is none; MIT is fine either way, and the app
is not aimed at the store regardless.
