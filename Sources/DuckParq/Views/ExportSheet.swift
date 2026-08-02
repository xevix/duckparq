import AppKit
import DuckParqCore
import SwiftUI

/// Export the current view — same filters, same ordering — via `COPY (...) TO`.
struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var format: SQLBuilder.ExportFormat = .csv
    @State private var limitToLoaded = true
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
                    .disabled(isExporting || app.table.currentQuery == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
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

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.message = "Choose where to write the exported rows"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        errorMessage = nil
        isExporting = true
        let copy = SQLBuilder.export(
            query: query,
            to: destination,
            format: format,
            limit: limitToLoaded ? app.table.rows.count : nil
        )

        exportTask = Task {
            do {
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

    private var suggestedFileName: String {
        let base = app.table.currentSource?.url.deletingPathExtension().lastPathComponent ?? "query"
        return "\(base)-export.\(format.fileExtension)"
    }
}
