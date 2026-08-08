import CDuckParq
import Foundation

/// One page of rows pulled from a cursor.
public struct RowPage: Sendable {
    /// Row-major, `rowCount * columnCount` entries. `nil` is SQL NULL.
    public let cells: [String?]
    public let rowCount: Int
    public let columnCount: Int
}

/// A streaming cursor over a query result.
///
/// The cursor holds the query open and pulls chunks on demand, which is what
/// makes scroll-to-load cheap: paging never re-runs the query, so a sort is
/// paid for once at open rather than once per page (as `LIMIT/OFFSET` would).
///
/// An actor, so concurrent scroll events can't fetch from the same cursor at
/// once. The blocking bridge call still runs on the session's private queue.
public actor QueryCursor {
    /// Boxed so the handle stays `Sendable` — see `UncheckedBox`. Set to nil
    /// once closed, which is also what makes `close()` idempotent.
    private var boxedHandle: UncheckedBox<dpq_cursor>?
    private let session: DuckDBSession
    /// Identifies this cursor's dedicated connection, released on close.
    private let connectionToken: Int
    public nonisolated let columnNames: [String]
    /// The `SQLTrace` entry for the statement this cursor is streaming, closed
    /// out by `close()` with everything it produced.
    private let trace: SQLTrace.Ticket?
    private var rowsFetched = 0

    init(
        handle: dpq_cursor,
        session: DuckDBSession,
        connectionToken: Int,
        trace: SQLTrace.Ticket? = nil
    ) {
        self.boxedHandle = UncheckedBox(handle)
        self.session = session
        self.connectionToken = connectionToken
        self.trace = trace
        let count = Int(dpq_cursor_column_count(handle))
        self.columnNames = (0..<count).map { index in
            dpq_cursor_column_name(handle, Int32(index)).map { String(cString: $0) } ?? "column\(index)"
        }
    }

    public var isOpen: Bool { boxedHandle != nil }

    /// Pull the next page. Returns nil at end of stream.
    public func fetch(maxRows: Int) async throws -> RowPage? {
        guard let boxed = boxedHandle else { return nil }
        let columnCount = columnNames.count

        let page: RowPage? = try await session.onQueue {
            var err: UnsafeMutablePointer<CChar>?
            guard let raw = dpq_cursor_fetch(boxed.value, Int32(maxRows), &err) else {
                if let message = takeMessage(&err) {
                    throw DuckDBError.engine(message)
                }
                return nil // end of stream
            }
            defer { dpq_rows_free(raw) }
            return Self.decode(raw, columnCount: columnCount)
        }

        rowsFetched += page?.rowCount ?? 0
        if page == nil { close() }
        return page
    }

    /// Decode the bridge's flat arena into Swift strings.
    private static func decode(_ raw: UnsafeMutablePointer<dpq_rows>, columnCount: Int) -> RowPage {
        let rows = Int(raw.pointee.rows)
        let cols = Int(raw.pointee.cols)
        let cellCount = rows * cols
        guard cellCount > 0,
              let bytes = raw.pointee.bytes,
              let offsets = raw.pointee.offsets,
              let nulls = raw.pointee.nulls
        else {
            return RowPage(cells: [], rowCount: rows, columnCount: columnCount)
        }

        var cells = [String?]()
        cells.reserveCapacity(cellCount)
        for cell in 0..<cellCount {
            if nulls[cell / 8] & UInt8(1 << (cell % 8)) != 0 {
                cells.append(nil)
                continue
            }
            let start = Int(offsets[cell])
            let end = Int(offsets[cell + 1])
            if end <= start {
                cells.append("")
            } else {
                let buffer = UnsafeBufferPointer(start: bytes + start, count: end - start)
                cells.append(String(decoding: buffer, as: UTF8.self))
            }
        }
        return RowPage(cells: cells, rowCount: rows, columnCount: cols)
    }

    public func close() {
        guard let boxed = boxedHandle else { return }
        boxedHandle = nil
        SQLTrace.finish(trace, rows: rowsFetched)
        dpq_cursor_close(boxed.value)
        session.releaseCursorConnection(connectionToken)
    }

    deinit {
        if let boxed = boxedHandle {
            // Dropped without being closed — an abandoned query still ends, so
            // the trace should not be left with a statement that never
            // finished.
            SQLTrace.finish(trace, rows: rowsFetched)
            dpq_cursor_close(boxed.value)
            session.releaseCursorConnection(connectionToken)
        }
    }
}
