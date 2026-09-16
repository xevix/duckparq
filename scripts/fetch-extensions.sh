#!/usr/bin/env bash
# Fetch and verify the loadable DuckDB extensions the bundle ships.
#
# Vortex is not one of the extensions the static-libs bundle carries, and there
# is no static archive published for it -- it exists only as a signed, loadable
# .duckdb_extension. So it is vendored here and copied into the .app, and
# DuckDBEngine LOADs it from the bundle at startup. Nothing is downloaded at
# run time: a shipped DuckParq reads vortex on a machine that has never seen
# duckdb.
#
# The signature is DuckDB's own, checked by DuckDB when it loads the file, so
# the app needs no `allow_unsigned_extensions`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read from fetch-duckdb.sh rather than pinned again here. An extension is built
# against one DuckDB version and refuses to load into another, so two pins that
# could drift apart would fail at run time in the shipped app -- where one pin
# cannot.
DUCKDB_VERSION="$(sed -n 's/^DUCKDB_VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/fetch-duckdb.sh")"
if [[ -z "$DUCKDB_VERSION" ]]; then
  echo "ERROR: could not read DUCKDB_VERSION from scripts/fetch-duckdb.sh" >&2
  exit 1
fi
# The extension repository spells the platform with an underscore where the
# static-libs asset uses a hyphen.
DUCKDB_PLATFORM="osx_arm64"

# Extension, and the SHA256 of the gzipped download.
#
# Unlike the static-libs zip, which is an immutable GitHub release asset, this
# URL is a path DuckDB publishes into and can republish. A mismatch here is
# therefore "the pinned build moved", not necessarily "someone tampered" --
# check the new file, then update the hash below.
VORTEX_SHA256="5674bfc9a2e55a06c2ac68f2a18935ce217e6ad5479b01dea8406346a3bfaf66"

VENDOR="$ROOT/Vendor/duckdb-extensions"
STAMP="$VENDOR/.stamp"
BASE="http://extensions.duckdb.org/${DUCKDB_VERSION}/${DUCKDB_PLATFORM}"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "${DUCKDB_VERSION}-${DUCKDB_PLATFORM}-${VORTEX_SHA256}" ]]; then
  echo "duckdb extensions for ${DUCKDB_VERSION} (${DUCKDB_PLATFORM}) already vendored"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="$BASE/vortex.duckdb_extension.gz"
echo "fetching $url"
curl -fL --retry 3 -o "$tmp/vortex.gz" "$url"

actual="$(shasum -a 256 "$tmp/vortex.gz" | cut -d' ' -f1)"
if [[ "$actual" != "$VORTEX_SHA256" ]]; then
  echo "ERROR: checksum mismatch for vortex.duckdb_extension.gz" >&2
  echo "  expected $VORTEX_SHA256" >&2
  echo "  actual   $actual" >&2
  echo "  (extensions.duckdb.org republishes into this path; verify, then re-pin)" >&2
  exit 1
fi
echo "checksum ok"

gunzip -c "$tmp/vortex.gz" > "$tmp/vortex.duckdb_extension"

rm -rf "$VENDOR"
mkdir -p "$VENDOR"
mv "$tmp/vortex.duckdb_extension" "$VENDOR/"

echo "${DUCKDB_VERSION}-${DUCKDB_PLATFORM}-${VORTEX_SHA256}" > "$STAMP"
echo "vendored vortex.duckdb_extension -> $VENDOR"
echo -n "  size: "; du -h "$VENDOR/vortex.duckdb_extension" | cut -f1
