import AppKit
import DuckParqCore
import SwiftUI

/// The row/column view.
///
/// Built by hand rather than with SwiftUI's `Table` because this needs three
/// things `Table` doesn't offer together: three-state sorting, columns that are
/// only known at runtime, and paging driven by scroll position.
///
/// Header and rows share **one** horizontal scroll view and **one** array of
/// column widths, so they cannot drift apart. An earlier version kept the header
/// outside the scroll view and mirrored the scroll offset onto it; header and
/// body were then two independent layouts, and the columns did not line up.
/// Nesting a vertical scroll view inside the horizontal one keeps the header
/// fixed while rows scroll, without anything needing to be kept in sync by hand.
struct DataGridView: View {
    @Environment(AppModel.self) private var app

    /// Widths the user has dragged, keyed by column name. Anything absent is
    /// measured from the content.
    @State private var widthOverrides: [String: CGFloat] = [:]
    @State private var selectedRow: Int?
    /// Rebuilt whenever a fresh result arrives, so widths re-measure per query.
    @State private var measuredSignature: String = ""

    private var table: TableModel { app.table }

    var body: some View {
        VStack(spacing: 0) {
            if table.columns.isEmpty && !table.isLoading {
                emptyState
            } else {
                let widths = columnWidths
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow(widths: widths)
                        Divider()
                        rowsList(widths: widths)
                    }
                    // At least as wide as the columns, but filling the viewport
                    // when they are narrower so row striping spans the window.
                    .frame(minWidth: widths.reduce(0, +), maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            StatusBar()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: resultSignature) { _, signature in
            // New shape of result: measure column widths again.
            if signature != measuredSignature {
                widthOverrides = [:]
                selectedRow = nil
                measuredSignature = signature
            }
        }
        .onCopyCommand { copyPayload() }
    }

    // MARK: - Header

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            // Keyed by position, not by column name: parquet files can carry
            // duplicate or empty column names, and identical ForEach ids would
            // drop cells and shift every column after them.
            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                HeaderCell(
                    column: column,
                    width: widths[index],
                    direction: table.sortDirection(for: column.name),
                    ordinal: table.sortOrdinal(for: column.name),
                    onToggle: { additive in table.toggleSort(column: column.name, additive: additive) },
                    onResize: { delta in resize(column, currentWidth: widths[index], by: delta) }
                )
            }
        }
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Rows

    private func rowsList(widths: [CGFloat]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(table.rows) { row in
                    RowView(
                        row: row,
                        columns: table.columns,
                        widths: widths,
                        isSelected: selectedRow == row.id
                    )
                    .onTapGesture { selectedRow = row.id }
                    .onAppear { table.loadMoreIfNeeded(displayedIndex: row.id) }
                }
                footer
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if table.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading more rows…").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
        } else if table.hitRowCap {
            // A memory guard, not the end of the data — say so, and let the
            // user decide to keep going.
            HStack(spacing: 8) {
                Text(capMessage(table))
                    .foregroundStyle(.secondary)
                Button("Keep Loading") { table.continuePastCap() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .padding(10)
        } else if table.reachedEnd, !table.rows.isEmpty {
            Text("End of results")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(10)
        }
    }

    /// The cap is a memory guard, so it should say how much is left rather than
    /// implying the result ends here.
    private func capMessage(_ table: TableModel) -> String {
        let loaded = table.rows.count.formatted()
        if let total = table.totalRowCount, total > table.rows.count {
            let remaining = (total - table.rows.count).formatted()
            return "Stopped at \(loaded) loaded rows — \(remaining) more match."
        }
        return "Stopped at \(loaded) loaded rows."
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tablecells")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(app.roots.isEmpty ? "Add a folder to start browsing" : "Select a parquet file")
                .foregroundStyle(.secondary)
            if app.roots.isEmpty {
                Button("Add Folder…") { app.addRoot() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Column widths

    /// Identity of the current result, so widths reset when the shape changes
    /// but not when more rows of the same query arrive.
    private var resultSignature: String {
        let mode: String
        switch table.mode {
        case .empty: mode = "empty"
        case .source(let source): mode = source.readPath
        case .sql(let text): mode = "sql:\(text.hashValue)"
        }
        return mode + "|" + table.columns.map(\.name).joined(separator: ",")
    }

    /// One width per column, computed once per render and handed to both the
    /// header and every row. Deriving these twice is what let them disagree.
    private var columnWidths: [CGFloat] {
        ColumnLayout.widths(for: table.columns, rows: table.rows, overrides: widthOverrides)
    }

    private func resize(_ column: ColumnInfo, currentWidth: CGFloat, by delta: CGFloat) {
        widthOverrides[column.name] = ColumnLayout.clamp(currentWidth + delta)
    }

    // MARK: - Copy

    /// ⌘C copies the selected row, or the visible column headers when nothing
    /// is selected, as TSV for pasting into a spreadsheet.
    private func copyPayload() -> [NSItemProvider] {
        let text: String
        if let selectedRow, let row = table.rows.first(where: { $0.id == selectedRow }) {
            text = row.cells.map { $0 ?? "" }.joined(separator: "\t")
        } else {
            text = table.columns.map(\.name).joined(separator: "\t")
        }
        return [NSItemProvider(object: text as NSString)]
    }
}

// MARK: - Header cell

private struct HeaderCell: View {
    let column: ColumnInfo
    let width: CGFloat
    let direction: SortDirection?
    let ordinal: Int?
    let onToggle: (Bool) -> Void
    let onResize: (CGFloat) -> Void

    @Environment(AppModel.self) private var app
    @State private var showsFilterPopover = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        HStack(spacing: 3) {
            Text(column.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let direction {
                Image(systemName: direction == .ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tint)
            }
            if let ordinal {
                Text("\(ordinal)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: 26, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle(NSEvent.modifierFlags.contains(.shift))
        }
        .help("\(column.name) — \(column.typeName)\nClick to sort ascending, descending, then unsorted. Shift-click to add a secondary sort.")
        .contextMenu {
            Button("Filter \(column.name)…") { showsFilterPopover = true }
            Divider()
            Button("Copy Column Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(column.name, forType: .string)
            }
        }
        .popover(isPresented: $showsFilterPopover) {
            FilterEditor(column: column) { filter in
                app.table.upsert(filter: filter)
                showsFilterPopover = false
            }
        }
        .overlay(alignment: .trailing) { resizeHandle }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                onResize(value.translation.width - lastTranslation)
                                lastTranslation = value.translation.width
                            }
                            .onEnded { _ in lastTranslation = 0 }
                    )
            }
    }
}

// MARK: - Row

private struct RowView: View {
    let row: TableModel.GridRow
    let columns: [ColumnInfo]
    let widths: [CGFloat]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Position-keyed for the same reason as the header, and so cell N
            // always lines up with header N.
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                cell(at: index, column: column)
            }
        }
        .frame(height: 20)
        .background(background)
    }

    @ViewBuilder
    private func cell(at index: Int, column: ColumnInfo) -> some View {
        let value = index < row.cells.count ? row.cells[index] : nil
        Group {
            if let value {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // NULL is a value, not blank — but it shouldn't shout.
                Text("NULL")
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 6)
        .frame(
            width: index < widths.count ? widths[index] : 100,
            alignment: column.kind.prefersTrailingAlignment ? .trailing : .leading
        )
        .help(value ?? "NULL")
    }

    private var background: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.22)
            } else if row.id.isMultiple(of: 2) {
                Color.clear
            } else {
                Color(nsColor: .alternatingContentBackgroundColors[1])
            }
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let table = app.table
        HStack(spacing: 10) {
            if table.isLoading {
                ProgressView().controlSize(.small)
                Text("Querying…")
            } else if let error = table.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).lineLimit(1).truncationMode(.middle).help(error)
            } else if !table.columns.isEmpty {
                Text(rowSummary(table))
                Text("·").foregroundStyle(.tertiary)
                Text("\(table.columns.count) columns")
                if !table.sort.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(sortSummary(table))
                }
            }
            Spacer()
            Text("DuckDB \(app.duckdbVersion)").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Always reports the total, not just what has been fetched — the grid only
    /// ever holds a preview, so "500 rows" alone would misrepresent the file.
    private func rowSummary(_ table: TableModel) -> String {
        let loaded = table.rows.count.formatted()
        guard let total = table.totalRowCount else {
            // The count is still running, or the statement has no row count.
            return table.isCountingRows ? "\(loaded) rows loaded · counting…" : "\(loaded) rows loaded"
        }
        if table.rows.count >= total {
            return "\(total.formatted()) rows"
        }
        return "\(loaded) of \(total.formatted()) rows"
    }

    private func sortSummary(_ table: TableModel) -> String {
        let parts = table.sort.map { "\($0.column) \($0.direction == .ascending ? "↑" : "↓")" }
        return "sorted by " + parts.joined(separator: ", ")
    }
}
