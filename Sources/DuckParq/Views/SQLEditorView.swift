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

    private var isEmpty: Bool {
        app.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

                fileControls

                Divider().frame(height: 14)

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
                .disabled(isEmpty)
                .help("Run the query (⌘↩)")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

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
        // Filters and sorts change the query behind the view, so the editor
        // follows them — but only while it is still showing that query. Text
        // you typed is never replaced; see `seedSQLFromView`.
        .onChange(of: app.table.viewSignature) { _, _ in app.seedSQLFromView() }
    }

    /// Format, save and open — each one click, with the library of previously
    /// saved queries behind a small chevron rather than in front of them.
    @ViewBuilder
    private var fileControls: some View {
        @Bindable var app = app

        Button {
            app.formatSQL()
        } label: {
            Label("Format", systemImage: "text.alignleft")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .disabled(isEmpty)
        .help("Re-indent the query. Only whitespace changes — the query still does exactly what it did.")

        Button {
            app.saveQuery()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .disabled(isEmpty)
        .help("Save this query as a .sql file (⌘S)")

        Button {
            app.openQuery()
        } label: {
            Label("Open", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .help("Load a .sql file into the editor (⇧⌘O)")

        if !app.savedQueries.isEmpty {
            Menu {
                Section("Saved") {
                    ForEach(app.savedQueries) { query in
                        Button(query.name) { app.loadQuery(from: query.url) }
                    }
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(app.savedQueries.map(\.url))
                }
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Queries you have saved before")
        }

        Toggle("Format on save", isOn: $app.formatsOnSave)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("Run the formatter over the query before writing the file")
    }
}
