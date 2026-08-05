# Contributing

Bug reports and patches are welcome. There is no CLA and no template — an issue
with a parquet file that renders wrong is worth more than a well-formatted one
without.

## Before opening a pull request

```bash
make smoke   # the static link and the parquet extension still work
make test    # a few hundred checks, a few seconds
```

Both need the `duckdb` CLI for fixtures (`brew install duckdb`). If you touched
anything about grid geometry, `BIG=1 make fixtures && make test` adds the scale
section on a 10M-row file.

## What the code expects of a change

**Queries go to DuckDB.** No client-side sorting, filtering or type formatting.
The grid holds a window into a result, so anything done to the rows in memory
describes a fragment and presents it as the whole. If a feature seems to need a
comparator in Swift, it probably needs a different query.

**User values are bound, never interpolated.** Paths and filter operands are
`$n` parameters cast at the comparison site. The exception is text written for
the user to read and edit.

**SQL from the editor stays read-only.** The classification comes from DuckDB's
parser, not from a pattern match on the text. If you add a statement kind,
`SQLPolicy` and its tests are where that decision lives.

**Tests assert the mechanism where the mechanism is the point.** The row window
is checked against DuckDB's query plan, not just its rows, because the value of
the `LIMIT` is entirely in the optimiser turning it into a Top-N. The formatter
is checked by re-tokenizing its output. Prefer that shape of test to a golden
string.

**No new dependencies.** The whole app is DuckDB plus the standard library, and
the shipped binary links nothing outside its bundle. That is what makes it a
single file that keeps working.

New code should read like the file it lands in: comments explain why a thing is
the way it is, not what the line does.

## License

By contributing you agree your work is licensed under the [MIT
License](LICENSE), same as the rest of the project. If a change vendors or links
anything new, it also needs an entry in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) — and see the "no new
dependencies" note above first.
