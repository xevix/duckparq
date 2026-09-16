#!/usr/bin/env bash
# Generate parquet and vortex fixtures used by the smoke gate, the tests, and
# manual QA. Uses the duckdb CLI (a build-time convenience only -- the app
# itself never shells out to duckdb).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/.fixtures"
VORTEX_EXT="$ROOT/Vendor/duckdb-extensions/vortex.duckdb_extension"

if ! command -v duckdb >/dev/null 2>&1; then
  echo "ERROR: the 'duckdb' CLI is required to generate fixtures (brew install duckdb)" >&2
  exit 1
fi

if [[ ! -f "$VORTEX_EXT" ]]; then
  echo "ERROR: $VORTEX_EXT missing -- run 'make extensions' first" >&2
  exit 1
fi

mkdir -p "$FIX"

# -init /dev/null so a user's ~/.duckdbrc can't perturb fixture generation.
run_sql() { duckdb -init /dev/null -c "$1"; }

# Vortex is written by the same extension the app ships and loads by path, not
# by whatever `INSTALL vortex` would fetch -- so the fixtures are written by
# exactly the build that reads them, and no network is needed to make them.
run_vortex_sql() { run_sql "LOAD '$VORTEX_EXT'; $1"; }

echo "==> small.parquet (1k rows)"
run_sql "
COPY (
  SELECT
    i                                             AS id,
    ['alpha','beta','gamma','delta'][(i % 4) + 1] AS category,
    (i * 7919) % 1000                             AS score,
    (i % 3) = 0                                   AS flagged,
    DATE '2024-01-01' + INTERVAL (i % 365) DAY    AS day,
    'row-' || i                                   AS label
  FROM range(1000) t(i)
) TO '$FIX/small.parquet' (FORMAT parquet);"

echo "==> types.parquet (nulls, decimal, list, struct, timestamptz, blob)"
run_sql "
SET TimeZone='UTC';
COPY (
  SELECT
    i                                            AS id,
    CASE WHEN i % 5 = 0 THEN NULL ELSE i * 1.5 END::DECIMAL(18,4) AS amount,
    CASE WHEN i % 7 = 0 THEN NULL ELSE 'txt-' || i END            AS maybe_text,
    [i, i + 1, i + 2]                            AS int_list,
    {'name': 'n' || i, 'size': i}                AS meta,
    TIMESTAMPTZ '2024-06-01 12:00:00+00' + INTERVAL (i) MINUTE    AS ts,
    ('blob-' || i)::BLOB                         AS payload,
    (i % 2 = 0)                                  AS even,
    i::HUGEINT * 100000000000000000              AS huge
  FROM range(200) t(i)
) TO '$FIX/types.parquet' (FORMAT parquet);"

echo "==> wide.parquet (200 columns)"
cols=$(python3 -c "print(', '.join(f'i * {n} AS c{n:03d}' for n in range(200)))")
run_sql "COPY (SELECT $cols FROM range(500) t(i)) TO '$FIX/wide.parquet' (FORMAT parquet);"

echo "==> hive/ (partitioned dataset)"
rm -rf "$FIX/hive"
run_sql "
COPY (
  SELECT
    i                                                AS id,
    2023 + (i % 2)                                   AS year,
    ['us','eu','apac'][(i % 3) + 1]                  AS region,
    (i * 31) % 500                                   AS value
  FROM range(3000) t(i)
) TO '$FIX/hive' (FORMAT parquet, PARTITION_BY (year, region));"

# A folder is a dataset when one glob covers its files without union_by_name.
# These three folders are the cases that decides: files that agree, files that
# do not, and files that agree on everything but the order of their columns --
# which DuckDB matches by name, so it globs them and they are a dataset too.
echo "==> uniform/ (a folder of files that agree on a schema)"
rm -rf "$FIX/uniform"
mkdir -p "$FIX/uniform"
run_sql "
COPY (SELECT i AS id, 'row-' || i AS label FROM range(500) t(i))
  TO '$FIX/uniform/part-0.parquet' (FORMAT parquet);
COPY (SELECT i AS id, 'row-' || i AS label FROM range(500, 1000) t(i))
  TO '$FIX/uniform/part-1.parquet' (FORMAT parquet);"

echo "==> mixed/ (a folder of files that do not)"
rm -rf "$FIX/mixed"
mkdir -p "$FIX/mixed"
run_sql "
COPY (SELECT i AS id, 'row-' || i AS label FROM range(100) t(i))
  TO '$FIX/mixed/labelled.parquet' (FORMAT parquet);
COPY (SELECT i AS id, i * 1.5 AS amount FROM range(100) t(i))
  TO '$FIX/mixed/priced.parquet' (FORMAT parquet);"

echo "==> reordered/ (same columns, different order)"
rm -rf "$FIX/reordered"
mkdir -p "$FIX/reordered"
run_sql "
COPY (SELECT i AS id, 'row-' || i AS label FROM range(100) t(i))
  TO '$FIX/reordered/id-first.parquet' (FORMAT parquet);
COPY (SELECT 'row-' || i AS label, i AS id FROM range(100) t(i))
  TO '$FIX/reordered/label-first.parquet' (FORMAT parquet);"

# --- vortex -------------------------------------------------------------
#
# Deliberately the same shapes as the parquet fixtures above, because what the
# tests are checking is that the app treats the two formats alike where the
# readers agree and differs only where they do not. A vortex fixture with its
# own schema would make every comparison a comparison of two things at once.

echo "==> small.vortex (1k rows, same columns as small.parquet)"
run_vortex_sql "
COPY (
  SELECT
    i                                             AS id,
    ['alpha','beta','gamma','delta'][(i % 4) + 1] AS category,
    (i * 7919) % 1000                             AS score,
    (i % 3) = 0                                   AS flagged,
    DATE '2024-01-01' + INTERVAL (i % 365) DAY    AS day,
    'row-' || i                                   AS label
  FROM range(1000) t(i)
) TO '$FIX/small.vortex' (FORMAT vortex);"

echo "==> uniform-vortex/ (a folder of vortex files that agree on a schema)"
rm -rf "$FIX/uniform-vortex"
mkdir -p "$FIX/uniform-vortex"
run_vortex_sql "
COPY (SELECT i AS id, 'row-' || i AS label FROM range(500) t(i))
  TO '$FIX/uniform-vortex/part-0.vortex' (FORMAT vortex);
COPY (SELECT i AS id, 'row-' || i AS label FROM range(500, 1000) t(i))
  TO '$FIX/uniform-vortex/part-1.vortex' (FORMAT vortex);"

echo "==> mixed-vortex/ (a folder of vortex files that do not)"
rm -rf "$FIX/mixed-vortex"
mkdir -p "$FIX/mixed-vortex"
run_vortex_sql "
COPY (SELECT i AS id, 'row-' || i AS label FROM range(100) t(i))
  TO '$FIX/mixed-vortex/labelled.vortex' (FORMAT vortex);
COPY (SELECT i AS id, i * 1.5 AS amount FROM range(100) t(i))
  TO '$FIX/mixed-vortex/priced.vortex' (FORMAT vortex);"

# Vortex has no hive_partitioning, so this folder is a dataset that globs as one
# table *without* year and region becoming columns of it. That is the difference
# the app has to show honestly rather than paper over -- see FileFormat.
echo "==> hive-vortex/ (key=value directories, laid out by hand)"
rm -rf "$FIX/hive-vortex"
for year in 2023 2024; do
  mkdir -p "$FIX/hive-vortex/year=$year"
  run_vortex_sql "
  COPY (SELECT i AS id, (i * 31) % 500 AS value FROM range(500) t(i))
    TO '$FIX/hive-vortex/year=$year/data_0.vortex' (FORMAT vortex);"
done

echo "==> both/ (parquet and vortex side by side -- not one table either way)"
rm -rf "$FIX/both"
mkdir -p "$FIX/both"
run_sql "COPY (SELECT i AS id FROM range(50) t(i)) TO '$FIX/both/a.parquet' (FORMAT parquet);"
run_vortex_sql "COPY (SELECT i AS id FROM range(50) t(i)) TO '$FIX/both/b.vortex' (FORMAT vortex);"

echo "==> corrupt.vortex (invalid file, for error paths)"
printf 'VORTEX1 this is not a valid vortex file' > "$FIX/corrupt.vortex"

echo "==> corrupt.parquet (invalid file, for error paths)"
printf 'PAR1this is not a valid parquet file' > "$FIX/corrupt.parquet"

if [[ "${BIG:-0}" == "1" ]]; then
  echo "==> big.parquet (10M rows) -- BIG=1"
  run_sql "
  COPY (
    SELECT
      i                                          AS id,
      hash(i) % 1000000                          AS bucket,
      'k' || (hash(i * 3) % 5000)                AS key,
      ['red','green','blue','white','black'][(i % 5) + 1] AS color,
      (i * 2654435761) % 100000 / 100.0          AS measure
    FROM range(10000000) t(i)
  ) TO '$FIX/big.parquet' (FORMAT parquet);"
else
  echo "==> skipping big.parquet (run with BIG=1 to generate the 10M-row file)"
fi

echo
du -sh "$FIX"/* | sed 's/^/  /'
