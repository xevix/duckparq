// swift-tools-version: 6.0
import PackageDescription
import Foundation

// DuckDB is vendored and statically linked, so the shipped .app has no external
// dependencies. `make vendor` (scripts/fetch-duckdb.sh) populates Vendor/duckdb.
// SwiftPM needs absolute paths in build settings, hence deriving the root here.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorInclude = "\(root)/Vendor/duckdb/include"
let vendorLib = "\(root)/Vendor/duckdb/lib"

// Statically linked DuckDB extensions register through the generated extension
// loader. The linker drops archive members nothing references, so without
// -force_load the parquet reader silently never registers. Kept in sync with
// FORCE_LOAD_LIBS in the Makefile.
let forceLoaded = [
    "libduckdb_generated_extension_loader.a",
    "libparquet_extension.a",
    "libcore_functions_extension.a",
    "libjson_extension.a",
    "libicu_extension.a",
    "libautocomplete_extension.a",
]

// swiftc drives the link, so -force_load has to be handed through with
// -Xlinker rather than the -Wl, spelling the Makefile's direct cc call uses.
let duckdbLinkerFlags: [String] =
    ["-L\(vendorLib)"]
    + forceLoaded.flatMap { ["-Xlinker", "-force_load", "-Xlinker", "\(vendorLib)/\($0)"] }
    + [
        "-lduckdb_static",
        "-lduckdb_fmt", "-lduckdb_pg_query", "-lduckdb_re2", "-lduckdb_miniz",
        "-lduckdb_utf8proc", "-lduckdb_hyperloglog", "-lduckdb_fastpforlib",
        "-lduckdb_skiplistlib", "-lduckdb_mbedtls", "-lduckdb_fsst",
        "-lduckdb_yyjson", "-lduckdb_zstd",
        "-lc++",
    ]

let package = Package(
    name: "DuckParq",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CDuckParq",
            cSettings: [.unsafeFlags(["-I\(vendorInclude)"])],
            linkerSettings: [.unsafeFlags(duckdbLinkerFlags)]
        ),
        // Engine + models live in a library so the self-test runner can import
        // them; the executable target holds only the app and its views.
        .target(
            name: "DuckParqCore",
            dependencies: ["CDuckParq"]
        ),
        .executableTarget(
            name: "DuckParq",
            dependencies: ["CDuckParq", "DuckParqCore"]
        ),
        // A Command Line Tools-only toolchain ships neither XCTest nor
        // swift-testing, so `swift test` is not available here. The suite is a
        // plain executable instead: same assertions, run by `make test`.
        .executableTarget(
            name: "DuckParqSelfTest",
            dependencies: ["CDuckParq", "DuckParqCore"]
        ),
    ]
)
