import Foundation

/// DuckDB's keyword list, read from the engine.
///
/// `duckdb_keywords()` is a table function the linked engine already answers —
/// 489 keywords at v1.5.5, categorised as reserved, unreserved, type_function
/// and column_name. Taking the list from there rather than hardcoding one means
/// the highlighter agrees with the parser by construction, including whatever a
/// future DuckDB adds.
///
/// Note what is deliberately *not* in it: `count`, `read_parquet` and other
/// functions are not keywords, and the CLI leaves them uncoloured too.
public final class SQLKeywords: @unchecked Sendable {
    public static let shared = SQLKeywords()

    private let lock = NSLock()
    private var words: Set<String> = SQLKeywords.bootstrap
    private var loadedFromEngine = false

    /// Uppercased keywords. Compare with `word.uppercased()`.
    public var all: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return words
    }

    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedFromEngine
    }

    /// Replace the bootstrap set with the engine's own. Cheap, and safe to call
    /// more than once.
    @discardableResult
    public func load(using session: DuckDBSession) async -> Bool {
        guard let batch = try? await session.queryAll(
            "SELECT upper(keyword_name) AS keyword FROM duckdb_keywords()",
            limit: 4096
        ) else { return false }

        let loaded = Set(batch.column("keyword").compactMap { $0 })
        guard loaded.count > 50 else { return false }

        store(loaded)
        return true
    }

    /// Separate from `load` because `NSLock.lock()` is unavailable in an async
    /// context — the compiler cannot see that nothing suspends while it is held.
    private func store(_ loaded: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        words = loaded
        loadedFromEngine = true
    }

    /// Enough to highlight ordinary SQL — in particular everything DuckParq
    /// generates itself — during the moment between launch and the engine
    /// answering. Not a maintained list: `load(using:)` replaces it wholesale.
    public static let bootstrap: Set<String> = [
        "ALL", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CAST", "COLUMNS", "CREATE",
        "CROSS", "DESC", "DISTINCT", "ELSE", "END", "EXCLUDE", "FALSE", "FROM", "FULL",
        "GROUP", "HAVING", "IN", "INNER", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT",
        "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "REPLACE",
        "RIGHT", "SELECT", "THEN", "TRUE", "UNION", "USING", "VALUES", "VIEW", "WHEN",
        "WHERE", "WITH",
    ]
}
