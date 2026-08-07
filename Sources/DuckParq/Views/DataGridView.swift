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
/// Layout numbers that cannot be asked about from outside the app.
///
/// `DUCKPARQ_TRACE=1` prints one line per distinct grid geometry. A scrollbar
/// for content that fits is not diagnosable from a screenshot — the interesting
/// quantity is the few points between the viewport and the content, and this
/// prints them rather than inferring them from the width of a thumb.
enum GridTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["DUCKPARQ_TRACE"] != nil
    nonisolated(unsafe) private static var last = ""

    /// `dedupe` suppresses a line identical to the previous one, which is what
    /// keeps a geometry that is recomputed on every render to one line. Events
    /// pass false: two identical clicks are two facts, not one.
    static func log(_ line: @autoclosure () -> String, dedupe: Bool = true) {
        guard isEnabled else { return }
        let text = line()
        if dedupe {
            guard text != last else { return }
            last = text
        }
        FileHandle.standardError.write(Data("[grid] \(text)\n".utf8))
    }
}

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
    /// Horizontal scroll offset, mirrored onto the header so it tracks the
    /// columns it labels.
    @State private var scrollX: CGFloat = 0
    /// Measured column widths, and the prefix sums used to find which columns
    /// the viewport is over.
    ///
    /// Held in state rather than recomputed per render because measuring means
    /// walking eighty rows of every column — a few milliseconds on a wide file,
    /// and the grid re-renders on every scroll tick. The measurement only
    /// depends on the columns and the first page of rows, so it is redone when
    /// those change and not otherwise.
    @State private var layout = GridLayout()

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
            remeasure()
        }
        // Measuring reads the first eighty rows, so it is redone when the rows
        // are replaced — and only then. Re-deriving it per render, which is
        // what a computed property amounted to, meant walking every column of
        // eighty rows on every scroll tick.
        .onChange(of: table.rowsGeneration) { _, _ in remeasure() }
        .onCopyCommand { copyPayload() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyleGeneration += 1
        }
    }

    private var grid: some View {
        // `remeasure()` runs from `onChange`, which lands a cycle after the
        // render that saw the new rows. Falling back to a fresh measurement for
        // that one frame is what keeps the grid from flashing empty; in the
        // steady state the counts match and nothing is computed here.
        let layout = self.layout.matches(table.columns)
            ? self.layout
            : GridLayout(columns: table.columns, rows: table.rows, overrides: widthOverrides)
        let widths = layout.widths
        let contentWidth = layout.contentWidth
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
            // Which columns the viewport is over. `LazyVStack` virtualizes down
            // the grid; this is the same idea across it, and on a wide file it
            // is the more important of the two. Without it every row builds a
            // cell for every column in the file — a two-thousand-column parquet
            // spent nineteen seconds on the main thread producing a screenful
            // in which a dozen columns were visible.
            let visibleColumns = ColumnLayout.visibleRange(
                offsets: layout.offsets, x: scrollX, width: viewport
            )
            let _ = GridTrace.log("""
                frame \(proxy.size.width.rounded()) viewport \(viewport.rounded()) \
                content \(contentWidth.rounded()) row \(rowWidth.rounded()) \
                inset \(verticalScrollerInset) \
                scrollers \(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay") \
                columns \(widths.count) visible \(visibleColumns.lowerBound)..<\(visibleColumns.upperBound)
                """)
            VStack(spacing: 0) {
                // The header is a sibling of the scroll view, not a pinned
                // section header inside it.
                //
                // Pinned works visually and is wrong where it counts: the pinned
                // header's hit region was placed as though the grid began at the
                // window's left edge, so every click landed a sidebar's width to
                // the right of where the header was drawn — about four columns
                // over, and off the end entirely for the last few. The header
                // renders in the right place and answers clicks in the wrong
                // one, which is why it looked like a sorting bug rather than a
                // layout one.
                //
                // Mirroring the scroll offset by hand costs a state variable and
                // keeps hit testing ordinary. Header and rows still derive from
                // one `widths` array and one `rowWidth`, both `.leading`, which
                // is what stops them drifting apart.
                headerRow(layout: layout, visible: visibleColumns)
                    .frame(width: rowWidth, alignment: .leading)
                    .offset(x: -scrollX)
                    .frame(width: viewport, alignment: .leading)
                    .clipped()
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(table.rows) { row in
                            RowView(
                                row: row,
                                generation: table.rowsGeneration,
                                columns: table.columns,
                                layout: layout,
                                visible: visibleColumns,
                                width: rowWidth,
                                isSelected: selectedRow == row.id
                            )
                            .equatable()
                            .onTapGesture { selectedRow = row.id }
                            .onAppear { table.loadMoreIfNeeded(displayedIndex: row.id) }
                        }
                        footer
                    }
                    .frame(width: rowWidth, alignment: .leading)
                }
                // Rows arrive after the scroll view exists, so its content goes
                // from zero-height to the whole first page in one step. With no
                // anchor declared it settled in the middle of that new content —
                // opening a file put you at row 250 of 500, halfway down a
                // dataset you had not scrolled. Anchoring to the top also keeps
                // the view still when a later page is appended below.
                .defaultScrollAnchor(.topLeading)
                // `contentOffset.x` is measured from the *inset* origin, and
                // this scroll view carries a leading inset the width of the
                // sidebar — NavigationSplitView insets its detail content so it
                // underlaps the translucent sidebar. At rest the offset is
                // therefore -327, not 0, and the sum with the inset is the
                // scroll position actually wanted.
                //
                // That inset is the whole original bug. A pinned section header
                // is laid out in content space, so its hit region sat a sidebar's
                // width to the right of where it was drawn, and clicking a column
                // sorted the one about four places over.
                //
                // Clamped to what the rows can actually scroll. The header
                // mirrors where the rows *are*, and the rows stop at the ends of
                // the content — so an offset outside that range describes a
                // position no row is in. Unclamped, the raw geometry drifts as
                // the content grows underneath it, and the header slid left on
                // every page that loaded while the columns themselves, having
                // nowhere to go, stayed put.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    let raw = geometry.contentOffset.x + geometry.contentInsets.leading
                    let scrollable = max(geometry.contentSize.width - geometry.containerSize.width, 0)
                    let clamped = min(max(raw, 0), scrollable)
                    GridTrace.log("""
                        scroll x \(geometry.contentOffset.x) inset \(geometry.contentInsets.leading) \
                        raw \(raw.rounded()) clamped \(clamped.rounded()) \
                        | y \(geometry.contentOffset.y.rounded()) \
                        topInset \(geometry.contentInsets.top) \
                        contentH \(geometry.contentSize.height.rounded()) \
                        containerH \(geometry.containerSize.height.rounded()) \
                        rows \(table.rows.count)
                        """)
                    return clamped
                } action: { _, x in
                    scrollX = x
                }
                // A two-axis scroll view flashes both indicators together, so
                // scrolling down drew a horizontal bar whose thumb filled the
                // whole track — an indicator for an axis with nothing to scroll.
                // Hidden rather than switching the axis set, which would rebuild
                // the scroll view and drop the scroll position every time a
                // resize crossed the point where the columns stop fitting.
                //
                // `.never`, not `.hidden`: `.hidden` is a preference the system
                // is free to overrule, and it does exactly that for the
                // always-visible scrollers this app draws — which is why hiding
                // it the first time changed nothing on screen. `.never` is the
                // one that means never.
                .scrollIndicators(contentWidth > viewport ? .automatic : .never,
                                  axes: .horizontal)
            }
        }
    }

    // MARK: - Header

    private func headerRow(layout: GridLayout, visible: Range<Int>) -> some View {
        let widths = layout.widths
        // Read once here, not inside the ForEach — `RowView` is handed its
        // columns for the same reason.
        //
        // `visible` describes the columns as they were when this header was
        // built, and SwiftUI re-runs a ForEach body whenever something the body
        // observed changes. A body reading `table.columns` live therefore
        // indexes the *new* columns with the *old* range, and emptying them
        // crashes it: closing a file, or removing the added folder the open
        // file was inside, clears the grid out from under a header still
        // describing eleven columns.
        let columns = table.columns
        return HStack(spacing: 0) {
            // A spacer standing in for the columns scrolled off to the left, so
            // the cells that are drawn land where the rows put theirs.
            if visible.lowerBound > 0 {
                Color.clear.frame(width: layout.offsets[visible.lowerBound], height: 26)
            }
            // Keyed by position, not by column name: parquet files can carry
            // duplicate or empty column names, and identical ForEach ids would
            // drop cells and shift every column after them.
            ForEach(visible, id: \.self) { index in
                // The snapshot and the range come from the same build, so this
                // holds — but a header cell for a column that is gone is not
                // worth crashing over if it ever stops holding.
                if index < columns.count, index < widths.count {
                    let column = columns[index]
                    HeaderCell(
                        column: column,
                        width: widths[index],
                        direction: table.sortDirection(for: column.name),
                        ordinal: table.sortOrdinal(for: column.name),
                        onToggle: { additive in
                            GridTrace.log("tap column \(index) \(column.name) additive \(additive)",
                                          dedupe: false)
                            table.toggleSort(column: column.name, additive: additive)
                            GridTrace.log("sort now [" + table.sort.map {
                                "\($0.column) \($0.direction.rawValue)"
                            }.joined(separator: ", ") + "]", dedupe: false)
                        },
                        onResize: { delta in resize(column, currentWidth: widths[index], by: delta) }
                    )
                }
            }
        }
        .frame(height: 26)
        .onAppear { traceHeaderLayout(widths) }
        .onChange(of: layout.version) { _, _ in traceHeaderLayout(layout.widths) }
    }

    /// Where each header cell actually is, so a click that sorts the wrong
    /// column can be checked against the geometry instead of guessed at.
    private func traceHeaderLayout(_ widths: [CGFloat]) {
        guard GridTrace.isEnabled else { return }
        var x: CGFloat = 0
        let spans = zip(table.columns, widths).map { column, width -> String in
            defer { x += width }
            return "\(column.name)@\(Int(x))-\(Int(x + width))"
        }
        GridTrace.log("header " + spans.joined(separator: " "))
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

    /// Re-derive the one width array the header and every row render from.
    /// Deriving these twice is what let them disagree.
    private func remeasure() {
        layout.update(columns: table.columns, rows: table.rows, overrides: widthOverrides)
    }

    private func resize(_ column: ColumnInfo, currentWidth: CGFloat, by delta: CGFloat) {
        widthOverrides[column.name] = ColumnLayout.clamp(currentWidth + delta)
        remeasure()
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

// MARK: - Layout

/// The measured column widths, plus the running x positions derived from them.
///
/// One value rather than two so they cannot be updated separately, and a
/// `version` rather than the arrays themselves for equality: every row on
/// screen compares against this, and on a wide file comparing two thousand
/// floats per row *is* the frame budget.
struct GridLayout: Equatable {
    private(set) var widths: [CGFloat] = []
    /// `offsets[i]` is where column `i` starts; the last entry is the total.
    private(set) var offsets: [CGFloat] = [0]
    /// Whether each column reads better right-aligned. Precomputed because
    /// `ColumnInfo.kind` uppercases the type name and walks a chain of prefix
    /// tests, and a cell would otherwise ask that question every time it was
    /// built.
    private(set) var trailingAligned: [Bool] = []
    /// Moves only when the widths actually change, so a re-measure that lands
    /// on the same numbers rebuilds nothing.
    private(set) var version = 0

    var contentWidth: CGFloat { offsets.last ?? 0 }

    init() {}

    init(columns: [ColumnInfo], rows: [TableModel.GridRow], overrides: [String: CGFloat]) {
        update(columns: columns, rows: rows, overrides: overrides)
    }

    /// Whether these widths still describe `columns`.
    func matches(_ columns: [ColumnInfo]) -> Bool { widths.count == columns.count }

    mutating func update(
        columns: [ColumnInfo],
        rows: [TableModel.GridRow],
        overrides: [String: CGFloat]
    ) {
        let measured = ColumnLayout.widths(for: columns, rows: rows, overrides: overrides)
        guard measured != widths else { return }
        widths = measured
        offsets = ColumnLayout.offsets(for: measured)
        trailingAligned = columns.map(\.kind.prefersTrailingAlignment)
        version += 1
    }

    static func == (lhs: GridLayout, rhs: GridLayout) -> Bool { lhs.version == rhs.version }
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

    /// The divider between columns, and the strip you grab to resize.
    ///
    /// The strip used to be centred on the divider, so half of it hung over the
    /// *next* column, and it swallowed clicks that never became drags. Between
    /// them that made an eight-point dead band on every boundary where a click
    /// sorted the wrong column or nothing at all — and on the last column, whose
    /// divider is the grid's right edge, there was no neighbour to fall back to,
    /// so it just did nothing.
    ///
    /// Now the strip sits entirely inside its own cell, and a click on it sorts
    /// that cell like any other part of the header. Only a drag resizes.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: Self.resizeGrabWidth)
                    .offset(x: -Self.resizeGrabWidth / 2)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .onTapGesture { onToggle(NSEvent.modifierFlags.contains(.shift)) }
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

    private static let resizeGrabWidth: CGFloat = 8
}

// MARK: - Row

private struct CellTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// A row of cells: the drawing, plus the one place it answers the pointer.
///
/// The cells are drawn rather than built as views. A `Text` with the modifiers a
/// cell needs costs about 135µs to materialise, and a row of a dozen of them
/// about 2ms — so a scroll that reveals ten rows in a frame blew a 16ms budget
/// on its own, however few columns were on screen. Drawing the same row costs
/// about a tenth of that, because it is one view rather than a dozen.
///
/// What views gave for free has to be put back by hand, and is: the pointer's
/// column is found from the same offsets the drawing uses, and the tooltip and
/// the context menu hang off the row rather than off each cell — one of each
/// instead of a dozen, which is a saving in its own right. The cost is
/// VoiceOver, which cannot see into a drawing; the row carries a spoken
/// description of its cells so it is not silent.
private struct RowView: View, Equatable {
    /// Same O(1) comparison as `RowCanvas`, so a change elsewhere in the grid —
    /// a selection, a scroll — does not re-evaluate every row's menu and
    /// tooltip. The row's own hover state still updates it; `@State` is not
    /// gated by this.
    nonisolated static func == (lhs: RowView, rhs: RowView) -> Bool {
        lhs.row.id == rhs.row.id
            && lhs.generation == rhs.generation
            && lhs.isSelected == rhs.isSelected
            && lhs.width == rhs.width
            && lhs.layout == rhs.layout
            && lhs.visible == rhs.visible
            && lhs.columns.count == rhs.columns.count
    }

    @Environment(AppModel.self) private var app

    let row: TableModel.GridRow
    /// Which result the cells came from — see `RowCanvas.==`.
    let generation: Int
    let columns: [ColumnInfo]
    let layout: GridLayout
    /// The columns to actually draw. Everything outside this range is skipped,
    /// so a thousand-column file costs a dozen cells per row.
    let visible: Range<Int>
    /// The full width of a row, which is the columns' total or the window,
    /// whichever is larger. The same value the header uses.
    let width: CGFloat
    let isSelected: Bool

    /// The column the pointer is over, which is what the menu and the tooltip
    /// are about.
    ///
    /// Held here rather than inside the canvas so that moving the mouse across
    /// the row re-evaluates only this wrapper: `RowCanvas` is `Equatable` and
    /// does not depend on the hover, so it compares equal and is not redrawn.
    @State private var hovered: Int?

    /// Roughly how wide one character of the 11pt monospaced cell font is.
    /// Used only to decide whether a value can already be read in full.
    private static let characterWidth: CGFloat = 6.6

    var body: some View {
        RowCanvas(
            row: row,
            generation: generation,
            layout: layout,
            visible: visible,
            width: width,
            isSelected: isSelected
        )
        .equatable()
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                // `point` arrives in the row's own coordinate space, which is
                // content space — the same space `layout.offsets` is in — so it
                // is used as-is.
                //
                // It is tempting to subtract the scroll view's leading content
                // inset here, because `NavigationSplitView` insets the detail
                // pane and the resting `contentOffset.x` really is -268 rather
                // than 0. Doing so is wrong, and wrong by about four columns:
                // the inset moves where the row is drawn, not where its own
                // origin is. Checking that against a *scrolled* grid cannot
                // tell you — set the clip origin to 0 and it is already 268
                // points from rest, so both formulas agree.
                hovered = ColumnLayout.columnIndex(offsets: layout.offsets, at: point.x)
            case .ended:
                hovered = nil
            }
        }
        // A tooltip is only worth showing when the cell is actually cut off.
        // One `.help` for the row, not one per cell: thousands of tracking
        // rectangles in a window is part of what made switching back to the app
        // feel slow. `.help("")` is still a `.help`, so the modifier has to be
        // absent, not empty.
        .modifier(CellTooltip(text: tooltip))
        .contextMenu { cellMenu() }
        // A drawing is opaque to VoiceOver, so the row says what it holds.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    /// The cell the pointer is over, if there is one.
    private var hoveredCell: (column: ColumnInfo, value: String?)? {
        guard let hovered, hovered < columns.count else { return nil }
        return (columns[hovered], hovered < row.cells.count ? row.cells[hovered] : nil)
    }

    private var tooltip: String? {
        guard let hovered, let cell = hoveredCell, let value = cell.value,
              hovered < layout.widths.count,
              CGFloat(value.count) * Self.characterWidth > layout.widths[hovered] - 12
        else { return nil }
        return value
    }

    @ViewBuilder
    private func cellMenu() -> some View {
        if let cell = hoveredCell {
            // Nested and binary columns are left out for the same reason the
            // filter popover leaves them out: their rendered text is a display
            // of the value, not something to compare against.
            if !app.table.isSQLMode, cell.column.kind != .nested, cell.column.kind != .binary {
                Button(filterLabel(column: cell.column, value: cell.value)) {
                    app.table.filter(column: cell.column, matching: cell.value)
                }
                Divider()
            }
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cell.value ?? "NULL", forType: .string)
            }
            Divider()
        }
        Button("Copy Row") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.cells.map { $0 ?? "" }.joined(separator: "\t"),
                                           forType: .string)
        }
    }

    private func filterLabel(column: ColumnInfo, value: String?) -> String {
        guard let value else { return "Filter \(column.name) is NULL" }
        let shown = value.count > 32 ? value.prefix(32) + "…" : value[...]
        return "Filter \(column.name) = \(shown)"
    }

    /// Only the columns on screen, and only their names and values — reading a
    /// thousand-column row aloud in full helps nobody.
    private var spokenDescription: String {
        visible.prefix(24).compactMap { index -> String? in
            guard index < columns.count else { return nil }
            let value = index < row.cells.count ? row.cells[index] : nil
            return "\(columns[index].name): \(value ?? "null")"
        }
        .joined(separator: ", ")
    }
}

/// The drawn cells of one row.
private struct RowCanvas: View, Equatable {
    /// Deliberately O(1). Comparing `row.cells` and the width array elementwise
    /// is O(columns) *per row on screen*, which on a wide file costs more than
    /// the drawing does. `generation` stands in for the cells — row ids are
    /// ordinals, so a re-sort hands back the same ids with different contents,
    /// and that is the only way a row's cells ever change.
    nonisolated static func == (lhs: RowCanvas, rhs: RowCanvas) -> Bool {
        lhs.row.id == rhs.row.id
            && lhs.generation == rhs.generation
            && lhs.isSelected == rhs.isSelected
            && lhs.width == rhs.width
            && lhs.layout == rhs.layout
            && lhs.visible == rhs.visible
    }

    let row: TableModel.GridRow
    let generation: Int
    let layout: GridLayout
    let visible: Range<Int>
    let width: CGFloat
    let isSelected: Bool

    static let height: CGFloat = 20
    /// Matches the padding the header cells use, so the two line up.
    private static let padding: CGFloat = 6

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for index in visible where index < layout.widths.count {
                draw(index, in: context)
            }
        }
        .frame(width: width, height: Self.height, alignment: .leading)
        .background(background)
    }

    private func draw(_ index: Int, in context: GraphicsContext) {
        let value = index < row.cells.count ? row.cells[index] : nil
        let x = layout.offsets[index]
        let cellWidth = layout.widths[index]

        let string = value ?? "NULL"
        let inner = CGRect(x: x + Self.padding, y: 0,
                           width: max(cellWidth - Self.padding * 2, 0), height: Self.height)

        var resolved = resolve(string, isNull: value == nil, in: context)
        var size = resolved.measure(in: Self.unbounded)

        // `.truncationMode(.tail)` is a `Text` affordance, and there is no
        // `Text` here — so the tail is cut by hand. The cell font is
        // monospaced, which is what makes "how many characters fit" a division
        // rather than a search: one measurement gives the character width, and
        // the prefix that fits follows from it.
        if size.width > inner.width, string.count > 1 {
            let characterWidth = size.width / CGFloat(string.count)
            let fits = max(Int((inner.width - characterWidth) / characterWidth), 1)
            if fits < string.count {
                resolved = resolve(String(string.prefix(fits)) + "…", isNull: value == nil, in: context)
                size = resolved.measure(in: Self.unbounded)
            }
        }

        let trailing = index < layout.trailingAligned.count && layout.trailingAligned[index]
        let originX = trailing ? inner.maxX - size.width : inner.minX
        let at = CGPoint(x: originX, y: (Self.height - size.height) / 2)

        // The clip is the backstop: the character-width estimate is exact for
        // the ASCII this grid mostly shows and approximate for anything wider,
        // and a value must never spill into its neighbour's column. Only worth
        // a layer when it can actually overflow.
        guard size.width > inner.width else {
            context.draw(resolved, at: at, anchor: .topLeading)
            return
        }
        context.drawLayer { layer in
            layer.clip(to: Path(inner))
            layer.draw(resolved, at: at, anchor: .topLeading)
        }
    }

    private static let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: height)

    private func resolve(
        _ string: String,
        isNull: Bool,
        in context: GraphicsContext
    ) -> GraphicsContext.ResolvedText {
        var text = Text(string).font(.system(size: 11, design: .monospaced))
        // NULL is a value, not blank — but it shouldn't shout.
        if isNull { text = text.foregroundStyle(.tertiary).italic() }
        return context.resolve(text)
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
