import Foundation

public struct SavedQuery: Identifiable, Hashable, Sendable {
    public let url: URL
    public let modified: Date?

    public var id: URL { url }
    /// Filename without the `.sql`, which is what the user named it.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(url: URL, modified: Date? = nil) {
        self.url = url
        self.modified = modified
    }
}

public enum QueryLibraryError: Error, LocalizedError, Equatable, Sendable {
    case tooLarge(bytes: Int, limit: Int)
    case notText

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes, let limit):
            return "That file is \(bytes / 1024) KB. Saved queries are capped at \(limit / 1024) KB."
        case .notText:
            return "That file isn't UTF-8 text, so it isn't a SQL query."
        }
    }
}

/// Saved queries, stored as plain `.sql` files.
///
/// Plain files rather than a database or a defaults blob: a `.sql` file opens in
/// any editor, diffs in git, and can be handed to the `duckdb` CLI unchanged.
///
/// The library directory is only a *default* location, not a boundary — queries
/// can be saved and opened anywhere. Nothing here trusts file contents: a loaded
/// query is text on its way to the editor, and it is checked against
/// `SQLPolicy` at run time like anything else the user might type.
public enum QueryLibrary {
    public static let fileExtension = "sql"

    /// A query is something a person wrote by hand. A file far larger than that
    /// is not one, and loading it would only wedge the editor.
    public static let maxFileBytes = 1 << 20  // 1 MB

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DuckParq/Queries", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory() throws -> URL {
        let url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Queries in the library directory, most recently modified first.
    public static func saved() -> [SavedQuery] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return SavedQuery(url: url, modified: values?.contentModificationDate)
            }
            .sorted { left, right in
                switch (left.modified, right.modified) {
                case (let a?, let b?): return a > b
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return left.name < right.name
                }
            }
    }

    public static func load(contentsOf url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > maxFileBytes {
            throw QueryLibraryError.tooLarge(bytes: size, limit: maxFileBytes)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes else {
            throw QueryLibraryError.tooLarge(bytes: data.count, limit: maxFileBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw QueryLibraryError.notText
        }
        return text
    }

    public static func save(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var body = text
        if !body.hasSuffix("\n") { body += "\n" }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A starting filename for the save panel, derived from what is on screen.
    public static func suggestedName(for source: DataSource?) -> String {
        guard let source else { return "query" }
        let stem = source.url.deletingPathExtension().lastPathComponent
        let cleaned = stem.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "query" : cleaned
    }
}
