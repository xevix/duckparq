import Foundation

/// What the grid is currently reading.
public enum DataSource: Sendable, Hashable {
    /// A single `.parquet` file.
    case file(URL)
    /// A directory treated as one dataset — hive-partitioned layouts and plain
    /// directories of parquet files both read as `dir/**/*.parquet`.
    case dataset(URL)

    public var url: URL {
        switch self {
        case .file(let url), .dataset(let url): return url
        }
    }

    public var displayName: String { url.lastPathComponent }

    /// The path handed to `read_parquet`. Always passed as a bound parameter,
    /// never interpolated, so paths containing quotes are harmless.
    public var readPath: String {
        switch self {
        case .file(let url): return url.path
        case .dataset(let url): return url.appendingPathComponent("**/*.parquet").path
        }
    }

    /// `read_parquet(...)` with the path as parameter `$index`.
    public func readExpression(parameterIndex: Int) -> String {
        switch self {
        case .file:
            return "read_parquet($\(parameterIndex))"
        case .dataset:
            // hive_partitioning surfaces key=value directory names as columns;
            // union_by_name tolerates files whose column order differs.
            return "read_parquet($\(parameterIndex), hive_partitioning = true, union_by_name = true)"
        }
    }
}
