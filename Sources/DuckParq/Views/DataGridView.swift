import AppKit
import DuckParqCore
import SwiftUI

/// The row/column view.
///
/// Built by hand rather than with SwiftUI's `Table` because this needs three
/// things `Table` doesn't offer together: three-state sorting, columns that are
/// only known at runtime, and paging driven by scroll position.
///
/// **One scroll view, both axes.** Header and rows share a single layout and a
/// single array of column widths, so they cannot drift apart; the header is a
/// pinned section header, which keeps it fixed vertically while it still scrolls
/// sideways with the columns it labels. Two earlier arrangements were worse: a
/// header outside the scroll view with a mirrored offset made header and body
/// independent layouts that did not line up, and nesting a vertical scroll view
/// inside a horizontal one put the vertical scrollbar against the last column
/// instead of against the window.
struct DataGridView: View {
    @Environment(AppModel.self) private var app

    /// Widths the user has dragged, keyed by column name. Anything absent is
    /// measured from the content.
    @State private var widthOverrides: [String: CGFloat] = [:]
    @State private var selectedRow: Int?
    /// Rebuilt whenever a fresh result arrives, so widths re-measure per query.
    @State private var measuredSignature: String = ""
    /// Bumped when the system switches between overlay and legacy scrollers,
    /// which happens the moment a mouse is plugged in. Without it the grid would
    /// keep the width it computed under the old style until something else
    /// invalidated it.
    @State private var scrollerStyleGeneration = 0

    private var table: TableModel { app.table }

    /// How much width an always-visible vertical scroller takes out of the
    /// scroll view's viewport.
    ///
    /// Overlay scrollers float above the content and take nothing; legacy ones
    /// are laid out beside it, so the content is offered ~15pt less than the
    /// scroll view's own frame.
    private var verticalScrollerInset: CGFloat {
        _ = scrollerStyleGeneration
        guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    /// Height of one data row, and of everything the rows are not.
    private static let rowHeight: CGFloat = 20
    private static let chromeHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if table.columns.isEmpty && !table.isLoading {
                emptyState
            } else {
                grid
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
        .onReceive(NotificationCenter.default.publisher(
            for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyleGeneration += 1
        }
    }

    private var grid: some View {
        let widths = columnWidths
        let contentWidth = widths.reduce(0, +)
        return GeometryReader { proxy in
            // At least as wide as the columns, and never narrower than the
            // window. Header and rows are both given this exact width and
            // `.leading`, so neither one's origin is left to a container's
            // default alignment. That is what knocked the header out of line
            // before: a VStack centres its children, so once the pinned header
            // was proposed the full window width its row of cells sat centred
            // in it while the data rows stayed left, offset by half the slack.
            //
            // "The window" is the scroll view's *viewport*, not its frame. With
            // legacy scrollers the vertical one is laid out beside the content
            // rather than over it, so filling the frame overflows the viewport
            // by exactly a scroller's width — and the grid grew a horizontal
            // scrollbar for columns that fit comfortably.
            let scrolls = CGFloat(table.rows.count) * Self.rowHeight
                + Self.chromeHeight > proxy.size.height
            let viewport = proxy.size.width - (scrolls ? verticalScrollerInset : 0)
            let rowWidth = max(contentWidth, viewport)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(table.rows) { row in
                            RowView(
                                row: row,
                                columns: table.columns,
                                widths: widths,
                                width: rowWidth,
                                isSelected: selectedRow == row.id
                            )
                            .onTapGesture { selectedRow = row.id }
                            .onAppear { table.loadMoreIfNeeded(displayedIndex: row.id) }
                        }
                        footer
                    } header: {
                        VStack(alignment: .leading, spacing: 0) {
                            headerRow(widths: widths)
                            Divider()
                        }
                        .frame(width: rowWidth, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: rowWidth, alignment: .leading)
            }
            // A two-axis scroll view flashes both indicators together, so
            // scrolling down drew a horizontal bar whose thumb filled the whole
            // track — an indicator for an axis with nothing to scroll. Hidden
            // rather than switching the axis set, which would rebuild the scroll
            // view and drop the scroll position every time a resize crossed the
            // point where the columns stop fitting.
            .scrollIndicators(contentWidth > viewport ? .automatic : .hidden, axes: .horizontal)
        }
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
    }

    // MARK: - Rows

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
    /// The full width of a row, which is the columns' total or the window,
    /// whichever is larger. The same value the header uses.
    let width: CGFloat
    let isSelected: Bool

    /// Roughly how wide one character of the 11pt monospaced cell font is.
    /// Used only to decide whether a value can already be read in full.
    private static let characterWidth: CGFloat = 6.6

    var body: some View {
        HStack(spacing: 0) {
            // Position-keyed for the same reason as the header, and so cell N
            // always lines up with header N.
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                cell(at: index, column: column)
            }
        }
        .frame(width: width, height: 20, alignment: .leading)
        .background(background)
    }

    @ViewBuilder
    private func cell(at index: Int, column: ColumnInfo) -> some View {
        let value = index < row.cells.count ? row.cells[index] : nil
        let width = index < widths.count ? widths[index] : 100
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
        .frame(width: width, alignment: column.kind.prefersTrailingAlignment ? .trailing : .leading)
        // A tooltip is only worth a tracking rectangle when the cell is actually
        // cut off. Attaching one to every cell put thousands of them in the
        // window, which AppKit revisits whenever the window becomes key — part
        // of what made switching back to the app feel slow.
        .help(isTruncated(value, width: width) ? (value ?? "") : "")
    }

    private func isTruncated(_ value: String?, width: CGFloat) -> Bool {
        guard let value else { return false }
        return CGFloat(value.count) * Self.characterWidth > width - 12
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
        HStack(spacing: 8) {
            if table.isBusy {
                ProgressView().controlSize(.small)
                Text(busyLabel(table))
                if let started = table.queryStartedAt {
                    // Driven by the clock rather than by the model publishing a
                    // tick, so a long query costs no redraws of the grid.
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(Self.duration(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("Cancel") { table.cancel() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Stop the running query in DuckDB")
            } else if let error = table.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).lineLimit(1).truncationMode(.middle).help(error)
            } else if !table.columns.isEmpty {
                Text(rowSummary(table))
                separator
                Text("\(table.columns.count) columns")
                if !table.sort.isEmpty {
                    separator
                    Text(sortSummary(table))
                }
                if table.wasCancelled {
                    separator
                    Text("cancelled").foregroundStyle(.orange)
                } else if table.servedFromCache {
                    separator
                    Text("cached")
                        .help("Shown from the last read of this file — it has not changed since. Use Clear Cache to force a re-read.")
                } else if let duration = table.lastQueryDuration {
                    separator
                    Text(Self.duration(duration))
                        .monospacedDigit()
                        .help("How long the query took to return its first page")
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

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func busyLabel(_ table: TableModel) -> String {
        if table.isLoading { return "Querying…" }
        if table.isLoadingMore { return "Loading more rows…" }
        return "Counting rows…"
    }

    /// Always reports the total, not just what has been fetched — the grid only
    /// ever holds a preview, so "500 rows" alone would misrepresent the file.
    private func rowSummary(_ table: TableModel) -> String {
        let loaded = table.rows.count.formatted()
        guard let total = table.totalRowCount else {
            // The count is still running, or the statement has no row count.
            return "\(loaded) rows loaded"
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

    /// Sub-second queries are the normal case here, so the short end gets the
    /// precision and anything slow enough to notice gets rounded.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.2fs", seconds) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}
