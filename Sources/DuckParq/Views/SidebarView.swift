import AppKit
import DuckParqCore
import SwiftUI

/// The file browser.
///
/// Children are read when a folder is first expanded rather than up front, so
/// adding a large directory tree stays instant.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var searchResults: [FileNode] = []

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            List {
                if app.searchQuery.isEmpty {
                    ForEach(app.roots, id: \.self) { root in
                        Section {
                            // A folder you added is often the dataset itself, so
                            // offer it directly rather than making you find a
                            // file inside it first.
                            if FileTree.looksLikeDataset(root) {
                                RootDatasetRow(url: root)
                            }
                            DirectoryContents(url: root, depth: 0)
                        } header: {
                            HStack {
                                Text(root.lastPathComponent)
                                Spacer()
                                Button {
                                    app.removeRoot(root)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                                .help("Remove \(root.lastPathComponent) from the sidebar")
                            }
                        }
                    }
                } else {
                    Section("Search results") {
                        if searchResults.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(searchResults) { node in
                            FileRow(node: node)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if app.roots.isEmpty {
                VStack(spacing: 8) {
                    Text("No folders yet").foregroundStyle(.secondary).font(.callout)
                    Button("Add Folder…") { app.addRoot() }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .searchable(text: $app.searchQuery, placement: .sidebar, prompt: "Filter by name")
        .onChange(of: app.searchQuery) { _, query in
            searchResults = app.roots.flatMap { FileTree.search(root: $0, query: query) }
        }
        .toolbar {
            ToolbarItem {
                Button { app.addRoot() } label: { Image(systemName: "plus") }
                    .help("Add a folder to browse (⌘O)")
            }
        }
    }
}

/// One level of a directory, loaded on first appearance.
private struct DirectoryContents: View {
    let url: URL
    let depth: Int

    @Environment(AppModel.self) private var app
    @State private var children: [FileNode] = []
    @State private var outcome: FileTree.ListingOutcome = .ok
    @State private var isLoaded = false

    var body: some View {
        // There is always exactly one row on screen, even before anything has
        // loaded. That matters: an empty ForEach renders no views at all, so a
        // .task attached to it has nothing to host it and never runs — which
        // left every folder permanently empty.
        if !isLoaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
            .task(id: url) { await load() }
        } else if outcome == .permissionDenied {
            // Downloads, Desktop and Documents are TCC-protected. Re-picking the
            // folder in an open panel is what actually grants access, so offer
            // exactly that rather than a dead end.
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS blocked access", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text("Re-select this folder to grant permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Grant Access…") {
                    if app.grantAccess(to: url) { reload() }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        } else if case .failed(let message) = outcome {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        } else if children.isEmpty {
            Text("No parquet files")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(children) { node in
                if node.isDirectory {
                    DirectoryRow(node: node, depth: depth)
                } else {
                    FileRow(node: node)
                }
            }
        }
    }

    private func reload() {
        isLoaded = false
        Task { await load() }
    }

    private func load() async {
        let url = self.url
        // Directory reads can be slow on network volumes; keep them off the
        // main actor so the sidebar stays responsive.
        let listing = await Task.detached(priority: .userInitiated) {
            FileTree.listing(of: url)
        }.value
        children = listing.nodes
        outcome = listing.outcome
        isLoaded = true
    }
}

/// Opens an added folder as one dataset — every parquet file beneath it.
private struct RootDatasetRow: View {
    let url: URL
    @Environment(AppModel.self) private var app

    private var node: FileNode {
        FileNode(url: url, isDirectory: true, isDataset: true, byteSize: nil, modified: nil)
    }

    private var isSelected: Bool { app.selection?.url == url }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(Color.accentColor)
            Text("All files as one dataset")
                .lineLimit(1)
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.select(node) }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .help("Read every parquet file under \(url.lastPathComponent) as a single table")
        .contextMenu { FileContextMenu(node: node) }
    }
}

private struct DirectoryRow: View {
    let node: FileNode
    let depth: Int

    @Environment(AppModel.self) private var app
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                DirectoryContents(url: node.url, depth: depth + 1)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDataset ? "square.stack.3d.up" : "folder")
                    .foregroundStyle(node.isDataset ? Color.accentColor : .secondary)
                Text(node.name).lineLimit(1)
                if node.isDataset {
                    // Hive layouts and folders of parquet files can be read as
                    // one table; the badge is also the affordance for doing so.
                    Text("dataset")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isDataset {
                    app.select(node)
                } else {
                    isExpanded.toggle()
                }
            }
            .help(node.isDataset
                  ? "Open every parquet file under \(node.name) as one dataset"
                  : node.url.path)
            .contextMenu { FileContextMenu(node: node) }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    @Environment(AppModel.self) private var app

    private var isSelected: Bool { app.selection?.url == node.url }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                if let size = node.formattedSize {
                    Text(size).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.select(node) }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .help(node.url.path)
        .contextMenu { FileContextMenu(node: node) }
    }
}

/// Right-click actions shared by files and dataset folders.
struct FileContextMenu: View {
    let node: FileNode
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Copy Path") { copy(node.url.path) }
        Button("Copy Name") { copy(node.name) }
        Button("Copy as read_parquet(…)") { copy(readExpression) }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    private var readExpression: String {
        SQLBuilder.readExpression(for: node.isDirectory ? .dataset(node.url) : .file(node.url))
    }

    /// Writes to the general pasteboard — the same place `pbcopy` writes, so the
    /// path is immediately pasteable in a terminal.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
