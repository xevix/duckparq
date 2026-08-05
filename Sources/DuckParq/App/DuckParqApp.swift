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

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowCapture.startIfRequested()
    }
}

/// Periodically writes a PNG of the app's own window.
///
/// The app draws itself, so it can photograph itself — no screen recording
/// permission, no capture of anything but this window. Enabled only by
/// `DUCKPARQ_SNAPSHOT=<path>`.
///
/// This exists because several layout defects — a centred header, a
/// zero-height list, a header whose hit region sat a sidebar's width off —
/// were all invisible to the tests and obvious in a picture.
enum WindowCapture {
    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DUCKPARQ_SNAPSHOT"] else { return }
        let autoScroll = environment["DUCKPARQ_AUTOSCROLL"].flatMap(Double.init)
        var frame = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let autoScroll { scrollDown(by: autoScroll) }
                let url = URL(fileURLWithPath: path)
                let numbered = url.deletingPathExtension()
                    .appendingPathExtension("\(frame)")
                    .appendingPathExtension(url.pathExtension)
                write(to: numbered.path)
                frame += 1
            }
        }
    }

    /// Scrolls the grid without a trackpad, so paging behaviour can be checked
    /// from a series of snapshots. Posting real scroll events would need
    /// accessibility permission; asking the view directly needs nothing.
    @MainActor
    private static func scrollDown(by points: Double) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView,
              let scroller = tallestScrollView(in: view)
        else { return }
        var origin = scroller.contentView.bounds.origin
        origin.y += points
        scroller.contentView.scroll(to: origin)
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    /// The grid's scroll view is the one with the most to scroll — the sidebar
    /// and the editor both have far less.
    @MainActor
    private static func tallestScrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ node: NSView) {
            if let scroller = node as? NSScrollView { found.append(scroller) }
            node.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }
    }

    @MainActor
    private static func write(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
