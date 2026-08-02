import CDuckParq
import Foundation

/// What DuckDB's parser says a statement is.
///
/// Raw values mirror `dpq_stmt_kind` in the C bridge; `SelfTest` asserts the two
/// stay in step. Anything unrecognised — including a statement type a future
/// DuckDB introduces — arrives as `.other`, which the read-only policy rejects.
public enum StatementKind: Int32, Sendable, CaseIterable {
    case other = 0
    case select = 1
    case explain = 2
    case insert = 3
    case update = 4
    case delete = 5
    case create = 6
    case drop = 7
    case alter = 8
    case copy = 9
    case export = 10
    case attach = 11
    case detach = 12
    case set = 13
    case load = 14
    case call = 15
    case transaction = 16
    case prepare = 17
    case execute = 18
    case vacuum = 19
    case analyze = 20

    /// How the statement is named in a rejection message.
    public var displayName: String {
        switch self {
        case .other: return "unrecognised"
        case .select: return "SELECT"
        case .explain: return "EXPLAIN"
        case .insert: return "INSERT"
        case .update: return "UPDATE"
        case .delete: return "DELETE"
        case .create: return "CREATE"
        case .drop: return "DROP"
        case .alter: return "ALTER"
        case .copy: return "COPY"
        case .export: return "EXPORT"
        case .attach: return "ATTACH"
        case .detach: return "DETACH"
        case .set: return "SET"
        case .load: return "INSTALL/LOAD"
        case .call: return "CALL"
        case .transaction: return "transaction control"
        case .prepare: return "PREPARE"
        case .execute: return "EXECUTE"
        case .vacuum: return "VACUUM"
        case .analyze: return "ANALYZE"
        }
    }
}

public enum SQLPolicyError: Error, LocalizedError, Equatable, Sendable {
    case empty
    case multipleStatements(Int)
    case notReadOnly(StatementKind)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "No statement to run."
        case .multipleStatements(let count):
            return """
                This query contains \(count) statements. DuckParq runs one \
                read-only statement at a time, so a script cannot smuggle a \
                write in behind a SELECT.
                """
        case .notReadOnly(let kind):
            return """
                \(kind.displayName) is not allowed — DuckParq is a viewer and \
                runs read-only queries. Use SELECT (also DESCRIBE, SUMMARIZE, \
                SHOW and EXPLAIN) to read the data.
                """
        }
    }
}

/// What SQL is permitted to do.
///
/// DuckParq is a viewer, so the answer is "read, and nothing else". The rule is
/// enforced on everything that runs through the SQL editor, not only on queries
/// loaded from a `.sql` file: once a file's text is in the editor buffer it is
/// indistinguishable from typed text, so a check that applied only at load time
/// would be defeated by touching a single character.
///
/// The decision is made from DuckDB's parse of the statement, never from the
/// text — see `dpq_statement_kinds`. Comments, unusual whitespace, nested
/// parentheses and creative casing are the parser's problem, not ours.
///
/// One honest limitation: DuckDB reports `PRAGMA` as a SELECT, so `PRAGMA`
/// statements pass. They read catalog information or adjust session settings;
/// none of them write data or touch the filesystem, and none can relax this
/// policy, which lives here rather than in a DuckDB setting.
public enum SQLPolicy {
    /// Statement kinds that only read.
    ///
    /// `.select` is broader than it looks: DuckDB parses `DESCRIBE`,
    /// `SUMMARIZE`, `SHOW`, `WITH …`, `VALUES …` and bare `FROM t` as SELECT.
    public static let readOnlyKinds: Set<StatementKind> = [.select, .explain]

    public static func isReadOnly(_ kind: StatementKind) -> Bool {
        readOnlyKinds.contains(kind)
    }

    /// Throws unless `kinds` is exactly one read-only statement.
    public static func validateReadOnly(_ kinds: [StatementKind]) throws {
        guard let first = kinds.first else { throw SQLPolicyError.empty }
        guard kinds.count == 1 else {
            throw SQLPolicyError.multipleStatements(kinds.count)
        }
        // Report the offending statement rather than the first one, so a script
        // whose write is buried at the end names the write.
        if let offender = kinds.first(where: { !isReadOnly($0) }) {
            throw SQLPolicyError.notReadOnly(offender)
        }
        guard isReadOnly(first) else { throw SQLPolicyError.notReadOnly(first) }
    }
}
