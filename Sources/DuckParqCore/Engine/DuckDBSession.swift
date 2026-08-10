import CDuckParq
import Foundation

public enum DuckDBError: Error, LocalizedError, Sendable {
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .engine(let message): return message
        }
    }

    /// The message DuckDB produces when a query is cancelled via interrupt.
    /// Cancellations are expected during normal browsing (the user changed sort,
    /// clicked another file) and should never surface as an error banner.
    public var isCancellation: Bool {
        guard case .engine(let message) = self else { return false }
        let lowered = message.lowercased()
        return lowered.contains("interrupt") || lowered.contains("cancel")
    }
}

/// The process-wide DuckDB instance. Parquet files are read from disk per query,
/// so an in-memory database is all that is needed.
public final class DuckDBEngine: @unchecked Sendable {
    public static let shared = try! DuckDBEngine()

    let db: dpq_db

    /// Where DuckDB spills to disk when a query outgrows memory.
    public let temporaryDirectory: URL

    /// An in-memory database's `temp_directory` defaults to `.tmp` — a
    /// *relative* path, resolved against the process's working directory. That
    /// is fine for a CLI started in a project folder and wrong for an
    /// application: a bundle launched from the Finder has `/` as its working
    /// directory, which is read-only, so the first query that needed to spill
    /// died with `Failed to create directory ".tmp": Read-only file system`.
    ///
    /// Nothing in the app hit it until parquet exports could partition, because
    /// a partitioned write is the first thing DuckParq does that buffers rows
    /// on disk rather than streaming them straight out — but the same fault was
    /// waiting for any sort large enough to spill.
    public static var defaultTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("duckparq", isDirectory: true)
    }

    public init(temporaryDirectory: URL = DuckDBEngine.defaultTemporaryDirectory) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard let handle = dpq_db_open(&err) else {
            throw DuckDBError.engine(takeMessage(&err) ?? "failed to open DuckDB")
        }
        self.db = handle
        self.temporaryDirectory = temporaryDirectory

        try? FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)

        // `temp_directory` is a global setting, so one connection sets it for
        // the instance and every session opened later inherits it. This one is
        // opened and closed here rather than kept: it exists to carry a single
        // SET, and holding it would mean holding a connection nothing queries.
        guard let conn = dpq_conn_open(handle, &err) else {
            throw DuckDBError.engine(takeMessage(&err) ?? "failed to connect")
        }
        defer { dpq_conn_close(conn) }
        let sql = "SET temp_directory = \(SQLBuilder.literal(temporaryDirectory.path))"
        guard dpq_exec(conn, sql, nil, 0, &err) else {
            throw DuckDBError.engine(takeMessage(&err) ?? "failed to set temp_directory")
        }
    }

    deinit { dpq_db_close(db) }

    public var duckdbVersion: String { String(cString: dpq_duckdb_version()) }
}

/// One DuckDB connection, serialized onto a dedicated thread.
///
/// Bridge calls block for as long as a query runs, so they must not occupy a
/// Swift cooperative thread — they get a private serial queue instead, with
/// continuations bridging back into async code.
///
/// Sessions are independent: cancelling one never disturbs another. DuckParq
/// keeps separate sessions for the grid, metadata probes, the SQL editor and
/// exports, so a slow sort can't block a schema lookup.
public final class DuckDBSession: @unchecked Sendable {
    private let engine: DuckDBEngine
    private let conn: dpq_conn
    private let queue: DispatchQueue

    /// Connections owned by open cursors, so `interrupt()` can reach them.
    ///
    /// DuckDB allows only one active streaming result per connection, so each
    /// cursor gets its own. Sharing one would mean opening a second cursor
    /// silently invalidates the first — which showed up as
    /// "Attempting to execute an unsuccessful or closed pending query result"
    /// whenever two probes on the same session overlapped.
    private let stateLock = NSLock()
    private var cursorConnections: [Int: dpq_conn] = [:]
    private var nextCursorToken = 0

    /// Names this session in an `SQLTrace` line, so a trace shows which of the
    /// four sessions ran a statement — the whole point of their being separate.
    private let label: String

    public init(engine: DuckDBEngine = .shared, label: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard let conn = dpq_conn_open(engine.db, &err) else {
            throw DuckDBError.engine(takeMessage(&err) ?? "failed to connect")
        }
        self.engine = engine
        self.conn = conn
        self.label = label
        self.queue = DispatchQueue(label: "dev.xevix.duckparq.session.\(label)")
    }

    deinit { dpq_conn_close(conn) }

    /// Cancel whatever this session is currently running, including any open
    /// cursors. Safe to call from any thread, including while the session's own
    /// queue is blocked in a query.
    public func interrupt() {
        dpq_conn_interrupt(conn)
        stateLock.lock()
        let connections = Array(cursorConnections.values)
        stateLock.unlock()
        for connection in connections {
            dpq_conn_interrupt(connection)
        }
    }

    /// Open a dedicated connection for a cursor. Cheap — DuckDB connections are
    /// lightweight handles onto the shared in-memory database.
    func makeCursorConnection() throws -> (token: Int, connection: dpq_conn) {
        var err: UnsafeMutablePointer<CChar>?
        guard let connection = dpq_conn_open(engine.db, &err) else {
            throw DuckDBError.engine(takeMessage(&err) ?? "failed to connect")
        }
        stateLock.lock()
        nextCursorToken += 1
        let token = nextCursorToken
        cursorConnections[token] = connection
        stateLock.unlock()
        return (token, connection)
    }

    func releaseCursorConnection(_ token: Int) {
        stateLock.lock()
        let connection = cursorConnections.removeValue(forKey: token)
        stateLock.unlock()
        if let connection { dpq_conn_close(connection) }
    }

    /// Run a statement for effect (CREATE VIEW, COPY, SET...).
    public func execute(_ sql: String, params: [String] = []) async throws {
        let trace = SQLTrace.begin(session: label, sql: sql, params: params)
        do {
            try await onQueue {
                var err: UnsafeMutablePointer<CChar>?
                let ok = withCStringArray(params) { pointers in
                    dpq_exec(self.conn, sql, pointers, Int32(params.count), &err)
                }
                guard ok else {
                    throw DuckDBError.engine(takeMessage(&err) ?? "query failed")
                }
            }
        } catch {
            SQLTrace.finish(trace, error: error)
            throw error
        }
        SQLTrace.finish(trace)
    }

    /// Classify the statements in `sql` using DuckDB's parser, without running
    /// any of them.
    ///
    /// Runs on this session's own connection, so views and settings this session
    /// can see are in scope while the statement is bound.
    public func statementKinds(_ sql: String) async throws -> [StatementKind] {
        try await onQueue {
            var err: UnsafeMutablePointer<CChar>?
            /// Anything past one statement is rejected regardless, so this only
            /// needs enough room to make that call.
            var buffer = [Int32](repeating: 0, count: 16)
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                dpq_statement_kinds(self.conn, sql, pointer.baseAddress, Int32(pointer.count), &err)
            }
            guard count >= 0 else {
                throw DuckDBError.engine(takeMessage(&err) ?? "could not parse the statement")
            }
            guard Int(count) <= buffer.count else {
                throw SQLPolicyError.multipleStatements(Int(count))
            }
            return (0..<Int(count)).map { StatementKind(rawValue: buffer[$0]) ?? .other }
        }
    }

    /// Reject `sql` unless it is a single read-only statement.
    ///
    /// Every path by which SQL a person wrote — typed, or opened from a `.sql`
    /// file — reaches DuckDB goes through here first. See `SQLPolicy`.
    public func validateReadOnly(_ sql: String) async throws {
        try SQLPolicy.validateReadOnly(try await statementKinds(sql))
    }

    /// Open a streaming cursor on its own connection. The caller owns it and
    /// must close it, which also releases that connection.
    ///
    /// `renderAsText` is the `SELECT COLUMNS(*)::VARCHAR FROM (…)` wrap that
    /// makes every column arrive as text. Turn it off only for a statement that
    /// cannot be selected from — `EXPLAIN` — whose output is already text. The
    /// decision belongs to the caller because it comes from the parsed
    /// statement kind, not from looking at the SQL.
    public func openCursor(
        _ sql: String,
        params: [String] = [],
        renderAsText: Bool = true
    ) async throws -> QueryCursor {
        let (token, connection) = try makeCursorConnection()
        let boxed = UncheckedBox(connection)
        // The cursor carries this and closes it out, since a streaming query
        // is not finished when it opens — it is finished when the last row has
        // been pulled, which is what the elapsed time should cover.
        let trace = SQLTrace.begin(session: label, sql: sql, params: params)
        do {
            return try await onQueue {
                var err: UnsafeMutablePointer<CChar>?
                let handle = withCStringArray(params) { pointers in
                    dpq_cursor_open_ex(
                        boxed.value, sql, pointers, Int32(params.count),
                        renderAsText ? 1 : 0, &err
                    )
                }
                guard let handle else {
                    throw DuckDBError.engine(takeMessage(&err) ?? "query failed")
                }
                return QueryCursor(
                    handle: handle, session: self, connectionToken: token, trace: trace
                )
            }
        } catch {
            SQLTrace.finish(trace, error: error)
            releaseCursorConnection(token)
            throw error
        }
    }

    /// Run a query and collect up to `limit` rows. For small, bounded results —
    /// schema probes, metadata, distinct-value lists.
    public func queryAll(_ sql: String, params: [String] = [], limit: Int = 10_000) async throws -> RowBatch {
        let cursor = try await openCursor(sql, params: params)
        defer { Task { await cursor.close() } }

        var columns: [String] = cursor.columnNames
        var cells: [String?] = []
        var rowCount = 0
        while rowCount < limit, let page = try await cursor.fetch(maxRows: min(1024, limit - rowCount)) {
            cells.append(contentsOf: page.cells)
            rowCount += page.rowCount
        }
        if columns.isEmpty { columns = [] }
        return RowBatch(columns: columns, cells: cells, rowCount: rowCount)
    }

    /// Hop onto the session's serial queue, bridging the blocking call.
    internal func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// A fully collected result: `cells` is row-major, `rowCount * columns.count` long.
public struct RowBatch: Sendable {
    public let columns: [String]
    public let cells: [String?]
    public let rowCount: Int

    public init(columns: [String], cells: [String?], rowCount: Int) {
        self.columns = columns
        self.cells = cells
        self.rowCount = rowCount
    }

    public subscript(row: Int, column: Int) -> String? {
        cells[row * columns.count + column]
    }

    public func value(row: Int, named name: String) -> String? {
        guard let index = columns.firstIndex(of: name) else { return nil }
        return self[row, index]
    }

    public func column(_ name: String) -> [String?] {
        guard let index = columns.firstIndex(of: name) else { return [] }
        return (0..<rowCount).map { self[$0, index] }
    }
}

// MARK: - C interop helpers

/// Carries a C handle across the hop onto a session's serial queue.
///
/// Opaque pointers aren't `Sendable`, and rightly so in general. It is safe
/// here because every use of a given handle is funnelled through one session's
/// serial queue, so no two threads ever touch it concurrently. The exception is
/// `dpq_conn_interrupt`, which DuckDB documents as safe to call from any thread.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Consume a `char **err` out-parameter, freeing the underlying string.
func takeMessage(_ err: inout UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer = err else { return nil }
    let message = String(cString: pointer)
    dpq_string_free(pointer)
    err = nil
    return message
}

/// Call `body` with a `const char *const *` view of `values`, valid for the
/// duration of the call.
func withCStringArray<R>(_ values: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
    guard !values.isEmpty else { return body(nil) }
    var copies = values.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    return copies.withUnsafeMutableBufferPointer { buffer in
        buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
            body(rebound.baseAddress)
        }
    }
}
