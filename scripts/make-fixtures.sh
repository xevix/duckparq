#!/usr/bin/env bash
# Generate parquet fixtures used by the smoke gate, the tests, and manual QA.
# Uses the duckdb CLI (a build-time convenience only -- the app itself never
# shells out to duckdb).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/.fixtures"

if ! command -v duckdb >/dev/null 2>&1; then
  echo "ERROR: the 'duckdb' CLI is required to generate fixtures (brew install duckdb)" >&2
  exit 1
fi

mkdir -p "$FIX"

# -init /dev/null so a user's ~/.duckdbrc can't perturb fixture generation.
run_sql() { duckdb -init /dev/null -c "$1"; }

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
