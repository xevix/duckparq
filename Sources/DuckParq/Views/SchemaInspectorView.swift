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

    private var source: DataSource? { app.table.currentSource }

    var body: some View {
        Group {
            if let source {
                content(for: source)
            } else {
                Text("No file selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source) { await load() }
    }

    @ViewBuilder
    private func content(for source: DataSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(source)

                if isLoading {
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
            VStack(alignment: .leading, spacing: 3) {
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
                    metadataRow("Rows", fileMetadata.value(row: 0, named: "num_rows"))
                    metadataRow("Row groups", fileMetadata.value(row: 0, named: "num_row_groups"))
                    metadataRow("File size", formattedBytes(fileMetadata.value(row: 0, named: "file_size_bytes")))
                    metadataRow("Format version", fileMetadata.value(row: 0, named: "format_version"))
                    metadataRow("Created by", fileMetadata.value(row: 0, named: "created_by"))
                    if fileMetadata.rowCount > 1 {
                        metadataRow("Files", "\(fileMetadata.rowCount)")
                    }
                }
            } header: {
                sectionHeader("File", subtitle: nil)
            }
        }
    }

    @ViewBuilder
    private var columnStatsSection: some View {
        if let columnMetadata, columnMetadata.rowCount > 0 {
            Section {
                VStack(alignment: .leading, spacing: 8) {
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

    private func load() async {
        guard let source else { return }
        isLoading = true
        loadError = nil
        fileMetadata = nil
        columnMetadata = nil
        keyValueMetadata = nil

        do {
            fileMetadata = try await app.probe.fileMetadata(of: source)
            columnMetadata = try await app.probe.columnMetadata(of: source)
            keyValueMetadata = try await app.probe.keyValueMetadata(of: source)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
