#!/usr/bin/env bash
# Fetch and verify the pinned DuckDB static libraries into Vendor/duckdb/.
#
# DuckParq links DuckDB statically, so the shipped .app depends on nothing
# outside its own bundle. The official static-libs bundle contains only the C
# API header (duckdb.h) -- that is why the bridge is written against the C API.
set -euo pipefail

DUCKDB_VERSION="v1.5.5"
DUCKDB_ARCH="osx-arm64"
DUCKDB_SHA256="d79ec66b8a4054b866faada82e9e31f859a713c555b3f1c4b71c4a43d3273e9c"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor/duckdb"
STAMP="$VENDOR/.stamp"
URL="https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/static-libs-${DUCKDB_ARCH}.zip"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "${DUCKDB_VERSION}-${DUCKDB_ARCH}" ]]; then
  echo "duckdb ${DUCKDB_VERSION} (${DUCKDB_ARCH}) already vendored"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "fetching $URL"
curl -fL --retry 3 -o "$tmp/static-libs.zip" "$URL"

actual="$(shasum -a 256 "$tmp/static-libs.zip" | cut -d' ' -f1)"
if [[ "$actual" != "$DUCKDB_SHA256" ]]; then
  echo "ERROR: checksum mismatch for static-libs-${DUCKDB_ARCH}.zip" >&2
  echo "  expected $DUCKDB_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
echo "checksum ok"

unzip -q "$tmp/static-libs.zip" -d "$tmp/unpacked"

rm -rf "$VENDOR"
mkdir -p "$VENDOR/include" "$VENDOR/lib"
mv "$tmp/unpacked/duckdb.h" "$VENDOR/include/"
mv "$tmp"/unpacked/*.a "$VENDOR/lib/"

echo "${DUCKDB_VERSION}-${DUCKDB_ARCH}" > "$STAMP"
echo "vendored duckdb ${DUCKDB_VERSION} (${DUCKDB_ARCH}) -> $VENDOR"
ls "$VENDOR/lib" | wc -l | xargs echo "  archives:"
