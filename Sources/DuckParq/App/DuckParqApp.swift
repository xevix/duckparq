import AppKit
import DuckParqCore
import SwiftUI

@main
struct DuckParqApp: App {
    @State private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 520)
                .onOpenURL { url in openPath(url) }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { commands }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { app.addRoot() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Query…") { app.openQuery() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Query…") { app.saveQuery() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(app.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { app.table.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Cancel Query") { app.table.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.table.isBusy)
            Divider()
            Button(app.showsSQLEditor ? "Hide SQL Editor" : "Show SQL Editor") {
                app.toggleSQLEditor()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button(app.showsInspector ? "Hide Inspector" : "Show Inspector") {
                app.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Format SQL") { app.formatSQL() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(app.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Button("Collapse All Folders") { app.collapseAll() }
                .disabled(app.expandedFolders.isEmpty)
            Button("Expand All Folders") { app.expandAll() }
                .disabled(app.roots.isEmpty)
            Divider()
            Button("Clear Sort") { app.table.clearSort() }
                .disabled(app.table.sort.isEmpty)
            Button("Clear Filters") { app.table.clearFilters() }
                .disabled(app.table.filters.isEmpty)
            Button("Clear Cache") { app.clearCache() }
        }
    }

    /// Opening a .parquet file from Finder adds its folder to the sidebar and
    /// selects the file.
    private func openPath(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        if !app.roots.contains(directory) {
            app.roots.append(directory)
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        app.select(FileNode(
            url: url,
            isDirectory: false,
            isDataset: false,
            byteSize: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate
        ))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
