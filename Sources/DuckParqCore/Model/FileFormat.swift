import Foundation

/// A columnar file format DuckParq can read.
///
/// Parquet and Vortex are the same shape of thing — a self-describing columnar
/// file, read by a table function that takes a path or a glob — so everything
/// above `DataSource` is written once and works for both. What is *not* the
/// same is how much the reader will tell you about a file it has opened, and
/// the flags below are that difference written down rather than rediscovered at
/// each call site.
///
/// Parquet is DuckDB's own; Vortex arrives through the `vortex` extension,
/// which the bundle ships and `DuckDBEngine` loads at startup. A build where
/// that load failed still reads parquet — see `requiredExtension`.
public enum FileFormat: String, Sendable, Hashable, CaseIterable, Codable {
    case parquet
    case vortex

    /// Filename extensions that name this format.
    ///
    /// `pq` and `parq` are the abbreviations parquet writers in the wild use.
    /// Vortex has only ever been written as `.vortex`, including by DuckDB's
    /// own `COPY ... (FORMAT vortex)`, so nothing is invented for it here.
    public var extensions: Set<String> {
        switch self {
        case .parquet: return ["parquet", "pq", "parq"]
        case .vortex: return ["vortex"]
        }
    }

    /// The table function that reads it.
    public var readFunction: String {
        switch self {
        case .parquet: return "read_parquet"
        case .vortex: return "read_vortex"
        }
    }

    /// The name `COPY ... (FORMAT …)` knows it by.
    public var copyFormatName: String { rawValue }

    /// How this format's files are named when they are globbed as one dataset.
    public var globSuffix: String { "**/*.\(primaryExtension)" }

    /// The extension an export writes, and the one a glob looks for.
    ///
    /// The same spelling as `copyFormatName` for both formats here, but not the
    /// same question: one is a filename, the other a word in a `COPY` statement.
    /// A format where they differ overrides this.
    public var primaryExtension: String { rawValue }

    /// Whether the reader takes `file_row_number` and `union_by_name`.
    ///
    /// `read_vortex` takes `hive_partitioning` and `filename` like parquet, but
    /// neither of these, and rejects them outright. What they buy has to
    /// degrade rather than fail on vortex: no `file_row_number` tiebreaker (see
    /// `DataSource.rowIdentityColumns`), no cheap schema-agreement probe (see
    /// `DatasetIndex.agreesFileByFile`), and no tolerance for files whose
    /// columns disagree.
    public var supportsRowNumbers: Bool {
        switch self {
        case .parquet: return true
        case .vortex: return false
        }
    }

    /// Whether DuckDB can describe the file's own storage — the row groups,
    /// codecs, per-column statistics and key/value footer the schema inspector
    /// shows.
    ///
    /// These come from `parquet_file_metadata`, `parquet_metadata` and
    /// `parquet_kv_metadata`, which have no vortex counterpart: the extension
    /// registers `read_vortex` and nothing else. The inspector shows the schema
    /// for a vortex file and leaves those sections out.
    public var describesStorage: Bool {
        switch self {
        case .parquet: return true
        case .vortex: return false
        }
    }

    /// Whether a `COPY` takes a `COMPRESSION` codec worth choosing.
    ///
    /// Vortex compresses with its own cascading encodings and exposes no codec
    /// choice, so there is nothing to offer.
    public var supportsCompressionChoice: Bool {
        switch self {
        case .parquet: return true
        case .vortex: return false
        }
    }

    /// The DuckDB extension that has to be loaded before this format can be
    /// read, or nil when the reader is compiled into the binary.
    ///
    /// What makes vortex the format that can be missing at run time. The engine
    /// loads one per format at startup and remembers which failed, so nothing
    /// above it has to know *which* format that is — see
    /// `DuckDBEngine.loadError(for:)`.
    public var requiredExtension: String? {
        switch self {
        case .parquet: return nil
        case .vortex: return "vortex"
        }
    }

    /// Every extension any readable format is named by.
    public static let allExtensions: Set<String> = allCases.reduce(into: []) {
        $0.formUnion($1.extensions)
    }

    /// The format a filename names, or nil for anything DuckParq does not read.
    public static func of(_ url: URL) -> FileFormat? {
        of(extension: url.pathExtension)
    }

    /// Built once. This is called twice for every entry of every directory the
    /// sidebar lists, and `extensions` is a computed `Set` — asking it directly
    /// allocated two of them per call.
    private static let byExtension: [String: FileFormat] = allCases.reduce(into: [:]) {
        table, format in
        for suffix in format.extensions { table[suffix] = format }
    }

    public static func of(extension suffix: String) -> FileFormat? {
        byExtension[suffix.lowercased()]
    }

    /// Whether a filename names a file DuckParq can read.
    public static func isReadable(_ url: URL) -> Bool { of(url) != nil }
}
