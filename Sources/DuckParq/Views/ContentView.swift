import DuckParqCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    /// Height of the SQL panel, dragged by the divider above it.
    @State private var sqlHeight: CGFloat = 150

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            VStack(spacing: 0) {
                FilterBarView()
                Divider()
                DataGridView()

                if app.showsSQLEditor {
                    ResizableDivider(height: $sqlHeight)
                    SQLEditorView()
                        .frame(height: sqlHeight)
                }
            }
            .navigationTitle(app.table.currentSource?.displayName ?? "DuckParq")
            .navigationSubtitle(app.table.isSQLMode ? "SQL result" : "")
            .toolbar { toolbarContent }
        }
        .inspector(isPresented: $app.showsInspector) {
            SchemaInspectorView()
                .inspectorColumnWidth(min: 240, ideal: 300, max: 460)
        }
        .sheet(isPresented: $app.showsExportSheet) {
            ExportSheet()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // Click re-runs; the menu holds the rarer, heavier action rather
            // than spending another toolbar slot on it.
            Menu {
                Button("Refresh") { app.table.reload() }
                Divider()
                Button("Clear Cache and Reload") { app.clearCache() }
            } label: {
                Image(systemName: "arrow.clockwise")
            } primaryAction: {
                app.table.reload()
            }
            .disabled(app.table.currentQuery == nil)
            .help("Re-run the current query (⌘R). Hold for cache options.")

            Button {
                app.showsExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(app.table.currentQuery == nil)
            .help("Export results…")

            Button {
                app.toggleSQLEditor()
            } label: {
                Image(systemName: "terminal")
            }
            .help("Show or hide the SQL editor (⇧⌘E)")

            Button {
                app.showsInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Show or hide schema and file metadata (⌥⌘I)")
        }
    }
}

/// Draggable divider for the SQL panel.
private struct ResizableDivider: View {
    @Binding var height: CGFloat
    @State private var startHeight: CGFloat?

    var body: some View {
        Divider()
            .frame(height: 5)
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = startHeight ?? height
                        if startHeight == nil { startHeight = height }
                        height = min(max(base - value.translation.height, 70), 500)
                    }
                    .onEnded { _ in startHeight = nil }
            )
    }
}
