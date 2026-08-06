import DuckParqCore
import SwiftUI

/// Schema and parquet file metadata for the current selection.
struct SchemaInspectorView: View {
    @Environment(AppModel.self) private var app

    @State private var fileMetadata: RowBatch?
    @State private var columnMetadata: RowBatch?
    @State private var keyValueMetadata: RowBatch?
    @State private var loadError: String?
    @State private var isLoading = false
    /// Set a second into a load. A dataset of many files takes long enough to
    /// be worth saying so; a single file almost never does, and a spinner that
    /// appears and vanishes is just a flash.
    @State private var showsProgress = false
    /// Row-group statistics were judged too expensive to run unasked.
    @State private var deferredColumnStats = false
    @State private var isLoadingColumnStats = false
    @State private var fingerprint: SourceFingerprint?

    /// Above this many row groups, `parquet_metadata` waits to be asked for.
    /// A few thousand is milliseconds; a dataset with tens of thousands is the
    /// case that made opening the panel feel broken.
    private static let automaticRowGroupLimit = 4_000

    private var source: DataSource? { app.table.currentSource }

    var body: some View {
        Group {
            // A hidden inspector is not a free one. SwiftUI builds `.inspector`
            // content whether or not the panel is open, so on a
            // two-thousand-column file this read the file's metadata and laid
            // out a row per column before anyone had asked to see either —
            // about a second of main thread for every file clicked, spent on a
            // panel that was not on screen. Nothing below is built, and no
            // metadata is read, until it is shown.
            if !app.showsInspector {
                Color.clear
            } else if let source {
                content(for: source)
            } else {
                Text("No file selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keyed on the source *and* on being visible, so opening the panel
        // reads what the selections made while it was shut deliberately did not.
        .task(id: app.showsInspector ? source : nil) {
            guard app.showsInspector else { return }
            await load()
        }
    }

    @ViewBuilder
    private func content(for source: DataSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(source)

                if isLoading && showsProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading metadata…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                schemaSection
                fileSection
                columnStatsSection
                keyValueSection
            }
            .padding(12)
        }
    }

    private func header(_ source: DataSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.displayName).font(.headline).lineLimit(2)
            Text(source.url.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var schemaSection: some View {
        Section {
            // Lazy, because this is one row per column and a parquet file can
            // carry thousands of them.
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(app.table.columns) { column in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(column.name)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer(minLength: 8)
                        Text(column.typeName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !column.isNullable {
                            Text("NOT NULL")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } header: {
            sectionHeader("Schema", subtitle: "\(app.table.columns.count) columns")
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if let fileMetadata, fileMetadata.rowCount > 0 {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    // Totals across the whole selection: for a dataset these are
                    // the sum over every file, computed in DuckDB.
                    if let files = fileMetadata.value(row: 0, named: "files"), files != "1" {
                        metadataRow("Files", files)
                    }
                    metadataRow("Rows", formattedCount(fileMetadata.value(row: 0, named: "num_rows")))
                    metadataRow("Row groups", formattedCount(fileMetadata.value(row: 0, named: "num_row_groups")))
                    metadataRow("Size", formattedBytes(fileMetadata.value(row: 0, named: "file_size_bytes")))
                    metadataRow("Format version", fileMetadata.value(row: 0, named: "format_version"))
                    metadataRow("Created by", fileMetadata.value(row: 0, named: "created_by"))
                }
            } header: {
                sectionHeader("File", subtitle: nil)
            }
        }
    }

    @ViewBuilder
    private var columnStatsSection: some View {
        if deferredColumnStats {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(rowGroupCount.formatted()) row groups across \(fileCountLabel). Reading their per-column statistics means opening every footer in the dataset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Read Column Statistics") { loadColumnStatsNow() }
                        .controlSize(.small)
                }
            } header: {
                sectionHeader("Columns", subtitle: "not loaded")
            }
        } else if isLoadingColumnStats {
            Section {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading row group statistics…").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                sectionHeader("Columns", subtitle: nil)
            }
        } else if let columnMetadata, columnMetadata.rowCount > 0 {
            Section {
                // One entry per row group per column, so lazy for the same
                // reason as the schema list — more so, since this multiplies.
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<columnMetadata.rowCount, id: \.self) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(columnMetadata.value(row: row, named: "column_name") ?? "—")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            HStack(spacing: 8) {
                                statPair("codec", columnMetadata.value(row: row, named: "compression"))
                                statPair("nulls", columnMetadata.value(row: row, named: "nulls"))
                            }
                            HStack(spacing: 8) {
                                statPair("min", columnMetadata.value(row: row, named: "min_value"))
                                statPair("max", columnMetadata.value(row: row, named: "max_value"))
                            }
                            if let compressed = columnMetadata.value(row: row, named: "compressed_bytes"),
                               let uncompressed = columnMetadata.value(row: row, named: "uncompressed_bytes") {
                                Text("\(formattedBytes(compressed) ?? compressed) compressed · \(formattedBytes(uncompressed) ?? uncompressed) raw")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                sectionHeader("Columns", subtitle: "row group statistics")
            }
        }
    }

    @ViewBuilder
    private var keyValueSection: some View {
        if let keyValueMetadata, keyValueMetadata.rowCount > 0 {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<keyValueMetadata.rowCount, id: \.self) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(keyValueMetadata.value(row: row, named: "key") ?? "—")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Text(keyValueMetadata.value(row: row, named: "value") ?? "—")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                sectionHeader("Key/value metadata", subtitle: nil)
            }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).bold()
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func metadataRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func statPair(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
        }
    }

    private func formattedBytes(_ raw: String?) -> String? {
        guard let raw, let value = Int64(raw) else { return raw }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func formattedCount(_ raw: String?) -> String? {
        guard let raw, let value = Int(raw) else { return raw }
        return value.formatted()
    }

    /// Read the source's metadata, cheapest question first.
    ///
    /// Three things make this fast enough to open on a large dataset:
    ///
    /// 1. It runs on the inspector's **own** DuckDB session. A session is a
    ///    serial queue, so when this shared one with the grid it queued behind
    ///    whatever the grid was doing — including a `count(*)` over billions of
    ///    rows, which is exactly when you want to look at the metadata.
    /// 2. The answers are cached against the same fingerprint as the preview, so
    ///    clicking back to a file you already inspected costs nothing.
    /// 3. Per-column row-group statistics are `parquet_metadata`, which is
    ///    O(row groups × columns) and reads every footer. The file summary is
    ///    O(files) and reports how many row groups there are — so it is asked
    ///    first, and used to decide whether the expensive one is worth running
    ///    without being asked.
    private func load() async {
        guard let source else { return }
        isLoading = true
        loadError = nil
        fileMetadata = nil
        columnMetadata = nil
        keyValueMetadata = nil
        deferredColumnStats = false

        showsProgress = false
        let delayedSpinner = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            showsProgress = true
        }
        defer {
            delayedSpinner.cancel()
            showsProgress = false
            isLoading = false
        }

        let fingerprint = await Task.detached(priority: .userInitiated) {
            SourceFingerprint.compute(for: source)
        }.value
        self.fingerprint = fingerprint
        if let fingerprint, let cached = PreviewCache.shared.stats(for: fingerprint) {
            fileMetadata = cached.fileSummary
            columnMetadata = cached.columnStatistics
            keyValueMetadata = cached.keyValues
            deferredColumnStats = cached.columnStatistics == nil
            return
        }

        // The cheap pair, concurrently.
        async let file: Void = loadFileMetadata(source)
        async let keyValues: Void = loadKeyValueMetadata(source)
        _ = await (file, keyValues)

        if rowGroupCount > Self.automaticRowGroupLimit {
            // Reading every row group's statistics here would cost more than
            // the whole rest of the panel. Say so and let it be asked for.
            deferredColumnStats = true
        } else {
            await loadColumnMetadata(source)
        }
        storeStats()
    }

    /// Run the deferred per-column statistics at the user's request.
    private func loadColumnStatsNow() {
        guard let source else { return }
        deferredColumnStats = false
        Task {
            isLoadingColumnStats = true
            await loadColumnMetadata(source)
            isLoadingColumnStats = false
            storeStats()
        }
    }

    private func storeStats() {
        guard let fingerprint, loadError == nil else { return }
        PreviewCache.shared.storeStats(
            CachedStats(
                fileSummary: fileMetadata,
                columnStatistics: columnMetadata,
                keyValues: keyValueMetadata
            ),
            for: fingerprint
        )
    }

    /// Total row groups across the source, from the cheap summary.
    private var rowGroupCount: Int {
        guard let raw = fileMetadata?.value(row: 0, named: "num_row_groups") else { return 0 }
        return Int(raw) ?? 0
    }

    private var fileCountLabel: String {
        let files = Int(fileMetadata?.value(row: 0, named: "files") ?? "1") ?? 1
        return files == 1 ? "this file" : "\(files.formatted()) files"
    }

    private func loadFileMetadata(_ source: DataSource) async {
        do { fileMetadata = try await app.probe.fileMetadata(of: source) } catch { record(error) }
    }

    private func loadColumnMetadata(_ source: DataSource) async {
        do { columnMetadata = try await app.probe.columnMetadata(of: source) } catch { record(error) }
    }

    private func loadKeyValueMetadata(_ source: DataSource) async {
        do { keyValueMetadata = try await app.probe.keyValueMetadata(of: source) } catch { record(error) }
    }

    /// First failure wins. Three concurrent reads of the same broken file would
    /// otherwise overwrite each other with the same message.
    private func record(_ error: Error) {
        guard loadError == nil else { return }
        loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
