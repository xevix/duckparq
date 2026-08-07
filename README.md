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

## License

DuckParq is [MIT licensed](LICENSE).

The app statically links DuckDB, which is MIT licensed as well.
