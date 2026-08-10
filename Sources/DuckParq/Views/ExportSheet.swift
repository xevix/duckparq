import AppKit
import DuckParqCore
import SwiftUI

/// Export the current view — same filters, same ordering — via `COPY (...) TO`.
struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var format: SQLBuilder.ExportFormat = .csv
    @State private var limitToLoaded = true
    @State private var isPartitioning = false
    @State private var partitionKeys: [String] = []
    @State private var orderBy = ""
    @State private var compression: SQLBuilder.ParquetCompression = .zstd
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Results").font(.headline)

            Picker("Format", selection: $format) {
                ForEach(SQLBuilder.ExportFormat.allCases) { candidate in
                    Text(candidate.rawValue).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isExporting)

            Picker("Rows", selection: $limitToLoaded) {
                Text("Loaded rows (\(app.table.rows.count.formatted()))").tag(true)
                Text(fullSetLabel).tag(false)
            }
            .pickerStyle(.radioGroup)
            .disabled(isExporting)

            if format == .parquet {
                Divider()
                parquetOptions
            }

            Text("Filters and sort order are applied by DuckDB, so the export matches exactly what the grid shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if isExporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting || app.table.currentQuery == nil || !isConfigured)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    // MARK: - Parquet layout

    /// Partitioning, a write ordering and a codec — the choices that only mean
    /// something for parquet, so they only appear for parquet.
    @ViewBuilder private var parquetOptions: some View {
        Picker("Compression", selection: $compression) {
            ForEach(SQLBuilder.ParquetCompression.allCases) { codec in
                Text(codec.rawValue).tag(codec)
            }
        }
        .pickerStyle(.menu)
        .disabled(isExporting)

        Toggle("Hive partitioning", isOn: $isPartitioning)
            .disabled(isExporting || partitionCandidates.isEmpty)

        if isPartitioning {
            partitionKeyList
            Text(partitionCaption)
                .font(.caption)
                .foregroundStyle(partitionKeys.isEmpty ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 4) {
            TextField("ORDER BY (optional)", text: $orderBy)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(isExporting)
            Text("""
                Sorting the rows before they are written makes them compress: \
                repeated values land next to each other. Any SQL expression \
                list, e.g. category, ts DESC.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One toggle per column. Clicking appends, so the checked order is the
    /// directory order — which is what the caption below spells out.
    private var partitionKeyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(partitionCandidates) { column in
                    Toggle(isOn: binding(for: column.name)) {
                        HStack(spacing: 6) {
                            Text(column.name)
                            Text(column.typeName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .frame(height: 110)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .disabled(isExporting)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { partitionKeys.contains(name) },
            set: { isOn in
                if isOn {
                    if !partitionKeys.contains(name) { partitionKeys.append(name) }
                } else {
                    partitionKeys.removeAll { $0 == name }
                }
            }
        )
    }

    private var partitionCandidates: [ColumnInfo] { app.table.displayColumns }

    private var partitionCaption: String {
        guard !partitionKeys.isEmpty else {
            return "Choose at least one column to partition by."
        }
        let path = partitionKeys.map { "\($0)=…" }.joined(separator: "/")
        return "Writes a folder: \(path)/data_0.parquet. Partition columns move into "
            + "the folder names, and a hive read puts them back."
    }

    private var layout: SQLBuilder.ParquetLayout {
        SQLBuilder.ParquetLayout(
            partitionBy: isPartitioning ? partitionKeys : [],
            orderBy: orderBy,
            compression: compression
        )
    }

    /// Whether the sheet describes an export that can be run. Partitioning by
    /// nothing is the one way to ask for something DuckDB cannot do.
    private var isConfigured: Bool {
        format != .parquet || !isPartitioning || !partitionKeys.isEmpty
    }

    private var fullSetLabel: String {
        if let total = app.table.totalRowCount {
            return "All matching rows (\(total.formatted()))"
        }
        return "All matching rows"
    }

    private func cancel() {
        if isExporting {
            // A COPY over a large file can run for a while; interrupting the
            // export session stops it without touching the grid's query.
            app.exportSession.interrupt()
            exportTask?.cancel()
            isExporting = false
        } else {
            dismiss()
        }
    }

    private func export() {
        guard let query = app.table.currentQuery else { return }

        let layout = self.layout
        let writesDirectory = SQLBuilder.writesDirectory(format: format, layout: layout)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName(directory: writesDirectory)
        panel.canCreateDirectories = true
        panel.message = writesDirectory
            ? "Choose where to write the partitioned dataset folder"
            : "Choose where to write the exported rows"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // A partitioned COPY writes into a folder without clearing it first, so
        // an export into one that already holds files would leave last time's
        // partitions sitting beside this time's — and a folder half of which is
        // stale still reads as one table, without complaint. Refused here
        // rather than by DuckDB, which says "not empty" and suggests the option
        // that would overwrite the folder's contents wholesale.
        if writesDirectory, let existing = try? FileManager.default
            .contentsOfDirectory(atPath: destination.path), !existing.isEmpty {
            errorMessage = "\(destination.lastPathComponent) already has files in it. "
                + "A partitioned export needs an empty folder, so its partitions are the only "
                + "thing in there."
            return
        }

        errorMessage = nil
        isExporting = true
        let limit = limitToLoaded ? app.table.rows.count : nil
        // Only an export carrying typed text has anything to check; without it
        // every part of the statement was built here.
        let writeOrder = format == .parquet ? layout.trimmedOrderBy : nil
        let check = writeOrder.map {
            SQLBuilder.exportCheck(query: query, limit: limit, orderBy: $0)
        }
        let copy = SQLBuilder.export(
            query: query,
            to: destination,
            format: format,
            limit: limit,
            layout: layout
        )

        exportTask = Task {
            do {
                // The ORDER BY is text the user wrote, and it is the only part
                // of this statement that is. Checking the body first means a
                // stray semicolon is rejected as a second statement rather than
                // run, and a misspelled column is named before anything is
                // written to the chosen path.
                if let check { try await app.exportSession.validateReadOnly(check) }
                try await app.exportSession.execute(copy.sql, params: copy.params)
                isExporting = false
                dismiss()
            } catch {
                isExporting = false
                if let duckError = error as? DuckDBError, duckError.isCancellation { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// A partitioned export names a folder, so it is offered without an
    /// extension — `sales-export.parquet` as a directory of parquet files would
    /// read as a lie in the Finder.
    private func suggestedFileName(directory: Bool) -> String {
        let base = app.table.currentSource?.url.deletingPathExtension().lastPathComponent ?? "query"
        return directory ? "\(base)-export" : "\(base)-export.\(format.fileExtension)"
    }
}
