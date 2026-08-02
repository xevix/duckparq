import AppKit
import DuckParqCore
import SwiftUI

/// The manual query panel.
///
/// Opening it over a selected file seeds it with the SQL driving the grid, so
/// the starting point is the query you are already looking at rather than a
/// blank box. The selection is also exposed as a view named `t`, so a query can
/// be as short as `SELECT * FROM t WHERE x > 1`.
///
/// Everything run from here is checked against `SQLPolicy` first — reads only,
/// one statement — which is why loading someone else's `.sql` file is safe.
struct SQLEditorView: View {
    @Environment(AppModel.self) private var app
    /// Picks between DuckDB's dark and light syntax palettes, the same choice
    /// the CLI makes by probing the terminal background.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var app = app

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("SQL").font(.caption).foregroundStyle(.secondary)

                Text("read-only")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.16), in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("Only single read-only statements run — SELECT, DESCRIBE, SUMMARIZE, SHOW, EXPLAIN")

                if let name = app.loadedQueryName {
                    Label(name, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if app.table.currentSource != nil {
                    Text(app.sqlMatchesView
                         ? "the SQL behind this view — edit freely"
                         : "the selection is available as `t`")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                queryFileMenu

                if app.table.currentSource != nil, !app.sqlMatchesView {
                    Button("View SQL") { app.seedSQLFromView(force: true) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Replace the editor with the SQL behind the current file view")
                }

                if let expression = app.readExpressionForInsertion {
                    Button("Insert Path") {
                        app.sqlText += (app.sqlText.isEmpty ? "SELECT * FROM " : "") + expression
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Insert the full read_parquet(...) call for the current selection")
                }

                if app.table.isSQLMode {
                    Button("Back to File View") { app.returnToFileView() }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                Button {
                    app.runSQL()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(app.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run the query (⌘↩)")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)

            Divider()

            SQLTextView(
                text: $app.sqlText,
                isDark: colorScheme == .dark,
                keywordsLoaded: app.sqlKeywordsLoaded
            )
            .background(Color(nsColor: .textBackgroundColor))
            .frame(minHeight: 60)

            // A rejected query leaves the grid on whatever it was showing, so
            // this cannot be gated on being in SQL mode — that is exactly the
            // case where the message would be swallowed.
            if let error = app.sqlError ?? app.table.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The library is a directory, so it can change outside the app; re-read
        // it whenever the panel appears rather than trusting a launch-time list.
        .task { app.refreshSavedQueries() }
    }

    /// Save, open, and the library of previously saved queries.
    private var queryFileMenu: some View {
        Menu {
            Button("Save Query…") { app.saveQuery() }
                .disabled(app.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Open Query…") { app.openQuery() }

            if !app.savedQueries.isEmpty {
                Divider()
                Section("Saved") {
                    ForEach(app.savedQueries) { query in
                        Button(query.name) { app.loadQuery(from: query.url) }
                    }
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(app.savedQueries.map(\.url))
                }
            }
        } label: {
            Label("Queries", systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save this query, or load one you saved earlier")
    }
}
