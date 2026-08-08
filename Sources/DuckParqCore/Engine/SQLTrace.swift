import Foundation

/// The SQL DuckParq actually runs, so what the grid asks DuckDB for can be
/// read rather than inferred.
///
/// Off unless `DUCKPARQ_SQL` is set:
///
/// * `DUCKPARQ_SQL=1` — write to stderr.
/// * `DUCKPARQ_SQL=~/duckparq.sql.log` — write there instead, which is the
///   usable one for a windowed app, whose stderr goes wherever it was launched
///   from. The file is truncated at launch, so a log is one run.
///
/// Statements are logged with their parameters already substituted, on one
/// line, so a line can be pasted into the `duckdb` CLI as it stands — which is
/// the point: the question a trace is usually opened to answer is whether the
/// query is the one you meant, and the fastest way to answer it is to run it.
///
/// That does mean the log carries the values a query ran on: the paths read,
/// and the operands of any filter. It is a record of what was looked at, so it
/// is worth reading before passing it on.
public enum SQLTrace {
    /// A statement in flight. Carried from the call that issued it to whatever
    /// finishes it, which for a cursor is a different object entirely.
    public struct Ticket: Sendable {
        let id: Int
        let session: String
        let started: Date
    }

    /// Resolved once. `nil` means tracing is off, which is the only check the
    /// hot paths do — an untraced build pays one optional test per query.
    private static let destination: FileHandle? = openDestination()
    private nonisolated(unsafe) static var sequence = 0
    private static let lock = NSLock()

    public static var isEnabled: Bool { destination != nil }

    private static func openDestination() -> FileHandle? {
        let environment = ProcessInfo.processInfo.environment
        guard let setting = environment["DUCKPARQ_SQL"], !setting.isEmpty else { return nil }

        let toStderr = ["1", "true", "yes", "stderr"].contains(setting.lowercased())
        guard !toStderr else { return FileHandle.standardError }

        // Anything else is a path. A trace that silently went nowhere because
        // the path was wrong would be worse than no trace at all, so a failure
        // to open it says so on stderr and keeps tracing there.
        let path = (setting as NSString).expandingTildeInPath
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            FileHandle.standardError.write(Data(
                "[sql] could not open \(path) for writing; tracing to stderr\n".utf8))
            return FileHandle.standardError
        }
        return handle
    }

    /// Record a statement being issued. The returned ticket must be handed to
    /// `finish` — `nil` when tracing is off, which `finish` ignores.
    public static func begin(session: String, sql: String, params: [String]) -> Ticket? {
        guard destination != nil else { return nil }

        lock.lock()
        sequence += 1
        let id = sequence
        lock.unlock()

        let statement = SQLBuilder.inlined(BoundSQL(sql: sql, params: params))
        write("[sql #\(id) \(session)] \(oneLine(statement))")
        return Ticket(id: id, session: session, started: Date())
    }

    /// Record how a statement ended. `rows` is what it produced, where the
    /// caller counts them; a statement run for effect reports none.
    public static func finish(_ ticket: Ticket?, rows: Int? = nil, error: Error? = nil) {
        guard let ticket, destination != nil else { return }
        let elapsed = Date().timeIntervalSince(ticket.started)
        let outcome: String
        if let error {
            outcome = "failed — \(error.localizedDescription)"
        } else if let rows {
            outcome = "\(rows) rows"
        } else {
            outcome = "ok"
        }
        write("[sql #\(ticket.id) \(ticket.session)] → \(outcome) in "
              + String(format: "%.3f", elapsed) + "s")
    }

    /// One statement, one line. The editor's SQL is formatted across lines and
    /// the builder's is not, and a trace you can `grep` is worth more than one
    /// that preserves either.
    private static func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func write(_ line: String) {
        guard let destination else { return }
        lock.lock()
        defer { lock.unlock() }
        destination.write(Data((line + "\n").utf8))
    }
}
