import Foundation

/// Which folders of parquet files read as one table.
///
/// A folder qualifies as a dataset two ways, and only one of them is a question
/// about names on disk. A hive layout announces itself — `key=value`
/// sub-directories are partition columns — and `FileTree` settles that half
/// itself, without reading a byte. The other half cannot be settled that way at
/// all: a folder of parquet files is one table only if the files agree on a
/// schema, and nothing in their names says whether they do.
///
/// So the question goes to the only authority on it, which is the reader that
/// would have to glob them. `SQLBuilder.schemaAgreement(under:)` runs the read
/// the folder would actually get, minus `union_by_name` — files that disagree
/// fail it with "schema mismatch in glob", and that failure *is* the answer.
/// Anything else that stops the read (an unreadable file, a folder macOS
/// refuses, no parquet files at all) is likewise not a dataset: a folder is
/// badged as one table only when it has been shown to be one.
///
/// Answers are remembered for the life of the process. The sidebar asks about a
/// folder every time it draws it and the filter field asks about every folder it
/// walks past, so without this a probe would run per keystroke. The cost is that
/// a folder which gains a file with a different schema keeps its badge until
/// relaunch — the same staleness the sidebar's own rows already carry, and
/// `invalidate()` is the way out of it.
public actor DatasetIndex {
    /// The index the sidebar uses, on a session of its own so a folder being
    /// classified can never delay the grid, the schema panel or an export.
    ///
    /// A session opens a connection onto the in-memory database and nothing
    /// else; if that fails the binary is broken, exactly as in `AppModel`.
    public static let shared = DatasetIndex(
        session: try! DuckDBSession(engine: .shared, label: "datasets")
    )

    private let session: DuckDBSession
    /// Keyed by path rather than by `URL`: the same folder arrives spelled
    /// `/a/b` from an open panel, `/a/b/` from a directory listing and
    /// `/private/a/b` from the filesystem watcher, and those are three unequal
    /// URLs. `path` at least settles the trailing slash.
    private var answers: [String: Bool] = [:]
    private var inFlight: [String: Task<Bool, Never>] = [:]

    public init(session: DuckDBSession) {
        self.session = session
    }

    /// Whether every parquet file under `directory` can be read through one
    /// glob — which is to say, whether the folder is a dataset.
    ///
    /// Concurrent askers share one probe: the sidebar draws a folder's row and
    /// its disclosure contents from the same URL, and both arrive at once.
    public func readsAsOneTable(_ directory: URL) async -> Bool {
        let key = directory.path
        if let answer = answers[key] { return answer }
        if let running = inFlight[key] { return await running.value }

        let session = self.session
        let task = Task<Bool, Never> {
            do {
                try await probe(SQLBuilder.schemaAgreement(under: directory), on: session)
                return true
            } catch let error as DuckDBError where error.isRowNumberCollision {
                // The folder holds a column literally called `file_row_number`,
                // so the cheap probe cannot be used on it at all. Ask again the
                // slow way rather than answering from a failure that says
                // nothing about whether the schemas agree.
                return (try? await probe(
                    SQLBuilder.schemaAgreementWithoutRowNumbers(under: directory), on: session
                )) != nil
            } catch {
                return false
            }
        }
        inFlight[key] = task
        let answer = await task.value
        inFlight[key] = nil
        answers[key] = answer
        return answer
    }

    /// Forget every answer, so the next question re-reads from disk.
    public func invalidate() {
        answers.removeAll()
    }

    /// Forget what was decided about one folder.
    ///
    /// What the watcher calls when a folder changes on disk. Whether a folder
    /// reads as one table is a fact about the files in it, so a file arriving or
    /// leaving is exactly the event that can overturn it — and the cached answer
    /// would otherwise survive until relaunch.
    public func invalidate(_ directory: URL) {
        answers.removeValue(forKey: directory.path)
    }

    /// Run a probe for its success or failure. The rows are of no interest —
    /// there are none, by construction — so only the error matters.
    private func probe(_ query: BoundSQL, on session: DuckDBSession) async throws {
        _ = try await session.queryAll(query.sql, params: query.params, limit: 1)
    }
}

extension DuckDBError {
    /// The refusal DuckDB gives for `file_row_number = true` on a file that
    /// already has a column of that name:
    ///
    ///     Using file_row_number option on file with column named
    ///     file_row_number is not supported
    ///
    /// Told apart from a schema mismatch because the two mean opposite things:
    /// a mismatch says the files disagree, this says the question was never
    /// asked. See `DataSource.rowNumberColumn` — the option takes a bool, so
    /// the name is not ours to move out of the way.
    ///
    /// Telling them apart takes more than the column's name. A mismatch lists
    /// the columns it *could* have bound to, and the generated one is among
    /// them — "Candidate names: id, amount, file_row_number" — so the bare name
    /// appears in both errors. What only the refusal says is that the option
    /// itself was the problem, and a mismatch is ruled out by its own wording
    /// besides: two readings of the same message rather than one, because
    /// getting this wrong costs a wasted glob on every folder that is not a
    /// dataset.
    public var isRowNumberCollision: Bool {
        guard case .engine(let message) = self else { return false }
        guard !message.contains(Self.schemaMismatch) else { return false }
        return message.contains("\(DataSource.rowNumberColumn) option")
    }

    /// The wording DuckDB uses when a glob's files disagree on their columns —
    /// the failure `DatasetIndex` is asking for, and never a collision.
    private static let schemaMismatch = "schema mismatch in glob"
}
