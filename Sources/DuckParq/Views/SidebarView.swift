import AppKit
import DuckParqCore
import SwiftUI

/// The file browser.
///
/// Children are read when a folder is first expanded rather than up front, so
/// adding a large directory tree stays instant. Which folders are open lives in
/// `AppModel`, not in each row — Collapse All has to be able to reach it.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var searchResults: [FileNode] = []
    @State private var revealWalk: Task<Void, Never>?

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            // The reader wraps the List so a row opened from Finder can be
            // scrolled to; rows are identified by their URL, which is what
            // AppModel asks for.
            ScrollViewReader { scroller in
                List {
                    if app.searchQuery.isEmpty {
                        RecentlyOpenedSection()

                        ForEach(app.roots, id: \.self) { root in
                            Section {
                                if app.isExpanded(root) {
                                    // A folder you added is often the dataset
                                    // itself, so offer it directly rather than
                                    // making you find a file inside it first.
                                    if FileTree.looksLikeDataset(root) {
                                        RootDatasetRow(url: root)
                                    }
                                    DirectoryContents(url: root, depth: 0)
                                }
                            } header: {
                                RootHeader(url: root)
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
                // Keyed on the nonce, not the route: revealing the same file
                // twice has to scroll twice.
                .onChange(of: app.revealNonce) { _, _ in
                    let route = app.revealRoute
                    revealWalk?.cancel()
                    revealWalk = Task { await walk(route, with: scroller) }
                }
            }

            if app.roots.isEmpty {
                VStack(spacing: 8) {
                    Text("No folders yet").foregroundStyle(.secondary).font(.callout)
                    HStack(spacing: 8) {
                        Button("Add Folder…") { app.addRoot() }
                        // Browsing a folder is not the only reason to be here;
                        // one file you already know the name of is the other.
                        Button("Open File…") { app.openFile() }
                    }
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
            ToolbarItemGroup {
                Button { app.addRoot() } label: { Image(systemName: "plus") }
                    .help("Add a folder to browse (⌘O)")

                Button { app.collapseAll() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(!app.canCollapseAll)
                .help("Collapse every folder")

                Button { app.expandAll() } label: {
                    if app.isExpandingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .disabled(app.roots.isEmpty || app.isExpandingAll)
                .help("Open every folder under the added roots")
            }
        }
    }

    /// Scroll down a route one folder at a time, ending on the row to show.
    ///
    /// A List builds rows only as they come near the viewport, so a file a
    /// hundred folders down does not exist to be scrolled to: asking for it
    /// directly does nothing at all, and the folder holding it is never even
    /// read from disk. Scrolling to each folder in turn is what brings the next
    /// one into existence.
    ///
    /// Each step waits for that folder's rows before reaching past them —
    /// briefly, and with a ceiling, because a folder on a slow volume is worth
    /// waiting for but not worth hanging the walk over. Giving up early costs
    /// the scroll, not the open: the file is selected and its folders are
    /// expanded regardless of how far this gets.
    @MainActor
    private func walk(_ route: [URL], with scroller: ScrollViewProxy) async {
        for (index, url) in route.enumerated() {
            withAnimation(.easeInOut(duration: 0.2)) {
                scroller.scrollTo(url, anchor: .center)
            }
            guard index < route.count - 1 else { return }

            // One beat for the row just scrolled to to be laid out, then up to
            // a second for its contents to arrive.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if app.isDirectoryListed(url) { break }
            }
        }
    }
}

/// Files opened from Finder that no added folder covers.
///
/// A metafolder, not a real one — its rows come from anywhere on disk, so each
/// one shows the folder it actually lives in, which is the thing you need to
/// tell two identically named exports apart.
private struct RecentlyOpenedSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let rows = app.recentlyOpenedRows
        if !rows.isEmpty {
            Section {
                if app.showsRecentlyOpened {
                    ForEach(rows) { node in
                        RecentlyOpenedRow(node: node)
                    }
                }
            } header: {
                header(count: rows.count)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(app.showsRecentlyOpened ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: app.showsRecentlyOpened)
                    .frame(width: 10)

                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Recently Opened").lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.showsRecentlyOpened.toggle() }
            .help("Files opened from Finder that are not in an added folder")

            Spacer(minLength: 12)

            Button {
                app.clearRecentlyOpened()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Clear all \(count) recently opened files")
        }
    }
}

/// A recently opened file. Same row as one in the tree, plus the folder it came
/// from — without a parent folder above it, the name alone says too little.
private struct RecentlyOpenedRow: View {
    let node: FileNode
    @Environment(AppModel.self) private var app

    private var isSelected: Bool { app.selection?.url == node.url }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                Text(node.url.deletingLastPathComponent().lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.select(node) }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .help(node.url.path)
        .contextMenu {
            FileContextMenu(node: node)
            Divider()
            Button("Remove from Recently Opened") { app.forgetRecentlyOpened(node.url) }
        }
    }
}

/// An added folder's header: its disclosure control, its name, and — kept well
/// away from both — the button that removes it.
///
/// The expansion is drawn here rather than left to `Section(isExpanded:)`,
/// which macOS puts at the *trailing* edge of a section header. That placed
/// "show me what's inside" immediately beside "remove this folder", so the two
/// adjacent controls were the most and the least recoverable actions in the
/// sidebar. The chevron now sits with the name it opens.
private struct RootHeader: View {
    let url: URL
    @Environment(AppModel.self) private var app

    private var isExpanded: Bool { app.isExpanded(url) }

    var body: some View {
        HStack(spacing: 0) {
            // Chevron and name are one target, so the name is clickable the way
            // a disclosure row's label normally is.
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
                    .frame(width: 10)

                Text(url.lastPathComponent).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.toggleExpanded(url) }
            .help(isExpanded ? "Collapse \(url.lastPathComponent)" : "Expand \(url.lastPathComponent)")

            // Nothing is clickable in between, so a miss on either control does
            // nothing rather than doing the other one.
            Spacer(minLength: 12)

            Button {
                app.removeRoot(url)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Remove \(url.lastPathComponent) from the sidebar")
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
        } else if outcome == .hivePartitioned {
            // The `key=value` folders under a hive layout are partitions of one
            // table. Listing them would invite opening a slice of a dataset as
            // though it were a file, so they are not offered at all.
            hiveNote
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

    private var hiveNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Hive-partitioned", systemImage: "square.grid.3x3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Partitions are columns of one table — open the folder itself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            // Same effect as tapping "All files as one dataset" for this
            // folder: hive partitions are a dead end to browse individually,
            // so clicking the note should just open the dataset.
            app.select(FileNode(url: url, isDirectory: true, isDataset: true, byteSize: nil, modified: nil))
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
        // A row cannot be scrolled to before it exists. This is what lets a
        // reveal walking down to a file know this folder's rows are there.
        app.directoryDidList(url)
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

    private var isExpanded: Binding<Bool> {
        Binding(get: { app.isExpanded(node.url) }, set: { app.setExpanded(node.url, $0) })
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            if isExpanded.wrappedValue {
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
                    app.toggleExpanded(node.url)
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
        // Only offered for a file the tree cannot already reach — which is
        // every row in Recently Opened, and none in the tree itself.
        if !node.isDirectory, !app.isCoveredByRoot(node.url) {
            Button("Add Containing Folder") { app.addContainingFolder(of: node.url) }
                .help("Browse \(node.url.deletingLastPathComponent().lastPathComponent) in the sidebar")
            Divider()
        }
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
