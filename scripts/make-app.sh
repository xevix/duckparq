#!/usr/bin/env bash
# Assemble DuckParq.app from the SwiftPM executable.
#
# There is no .xcodeproj and no xcodebuild in this project -- the bundle is
# built by hand from the SwiftPM executable. (Xcode itself may well be
# installed; the Makefile borrows its SwiftUI macro plugin when the active
# developer directory has none. It is the project file this does without, not
# the toolchain.) DuckDB is linked statically, so there is no Frameworks/
# directory, no dylib to copy and no install_name_tool fixups: the executable is
# the whole app, bar the one extension in Resources/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/DuckParq.app"
EXECUTABLE="$BUILD/release/DuckParq"
VORTEX_EXT="$ROOT/Vendor/duckdb-extensions/vortex.duckdb_extension"
BUNDLE_ID="dev.xevix.duckparq"

# The bundle's version comes from the git tag, not a constant that goes stale
# the moment one is cut. DUCKPARQ_VERSION overrides it, which is what the
# release workflow passes: on a tag push the runner has the ref name for
# certain, where a shallow clone's history is not guaranteed to describe.
#
# CFBundleShortVersionString has to be one to three dot-separated integers, so
# a tag loses its leading v and any pre-release suffix -- v1.1.0-rc.1 becomes
# 1.1.0. An untagged tree reports the nearest tag behind it, and 0.0.0 in a
# checkout with no tags at all.
VERSION="${DUCKPARQ_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
VERSION="${VERSION%%-*}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  [[ -n "$VERSION" ]] && echo "WARNING: '$VERSION' is not a usable version; using 0.0.0" >&2
  VERSION="0.0.0"
fi

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "ERROR: $EXECUTABLE not found -- run 'make release' first" >&2
  exit 1
fi

# A bundle without it launches and reads parquet, which is a worse failure than
# not building: it ships silently unable to open half the formats it claims in
# its own document types.
if [[ ! -f "$VORTEX_EXT" ]]; then
  echo "ERROR: $VORTEX_EXT not found -- run 'make extensions' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/DuckParq"

# Two document type entries per format, on purpose.
#
# Neither parquet nor vortex has a system UTI, so every viewer invents one and
# only one of them wins the extension in the Launch Services database. The first
# entry of each pair claims files typed as our own declaration below; the second
# claims the extension directly, the legacy spelling, which still binds when
# some other app's UTI is the one that won. Launch Services folds them into a
# single "DuckParq" row in Open With.
#
# The rank is what actually gets us recommended: Alternate means "I can open
# this but prefer someone else", which buries the app at the bottom of Open
# With. Default means "I am a reasonable handler for this", which is what Tad
# claims and what puts an app in Finder's recommended set. Owner would claim we
# defined the format, which Apache did.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DuckParq</string>
  <key>CFBundleDisplayName</key><string>DuckParq</string>
  <key>CFBundleExecutable</key><string>DuckParq</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Parquet File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key>
      <array><string>${BUNDLE_ID}.parquet</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Parquet File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>parquet</string><string>pq</string><string>parq</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Vortex File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key>
      <array><string>${BUNDLE_ID}.vortex</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Vortex File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>vortex</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>${BUNDLE_ID}.parquet</string>
      <key>UTTypeDescription</key><string>Apache Parquet File</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>parquet</string><string>pq</string><string>parq</string></array>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>${BUNDLE_ID}.vortex</string>
      <key>UTTypeDescription</key><string>Vortex File</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>vortex</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# DuckDB and the libraries it vendors are compiled into the executable, so
# their notices have to travel with the bundle rather than with the repo.
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/Contents/Resources/"

# Vortex is the one reader that is not compiled in -- there is no static archive
# published for it, only this signed loadable extension. It goes in Resources,
# which is where DuckDBEngine.extensionURL(named:) looks first in a shipped app,
# and is LOADed by path at startup. Nothing is ever downloaded at run time.
cp "$VORTEX_EXT" "$APP/Contents/Resources/"

# Ad-hoc signature: enough for local use, and macOS refuses to launch an
# unsigned arm64 binary from a bundle.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "WARNING: ad-hoc codesign failed; the app may not launch" >&2
}

echo "built $APP"
echo "  version: $VERSION"
echo -n "  size: "; du -sh "$APP" | cut -f1
echo -n "  vortex extension: "; du -h "$APP/Contents/Resources/vortex.duckdb_extension" | cut -f1
echo "  external dylibs: $(otool -L "$APP/Contents/MacOS/DuckParq" | grep -c duckdb || true) duckdb references"
