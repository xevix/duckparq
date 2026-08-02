import DuckParqCore
import SwiftUI

/// Active filters, shown as chips. Filters are ANDed and compiled to a WHERE
/// clause — none of this narrows rows locally.
struct FilterBarView: View {
    @Environment(AppModel.self) private var app
    @State private var showsColumnPicker = false

    var body: some View {
        let table = app.table
        HStack(spacing: 6) {
            Menu {
                ForEach(table.columns) { column in
                    Button {
                        pendingColumn = column
                    } label: {
                        Label("\(column.name)  ·  \(column.typeName)", systemImage: iconName(for: column.kind))
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(table.columns.isEmpty || table.isSQLMode)
            .help(table.isSQLMode
                  ? "Column filters don't apply to SQL results — edit the query instead"
                  : "Add a column filter")

            ForEach(table.filters) { filter in
                FilterChip(filter: filter)
            }

            if !table.filters.isEmpty {
                Button("Clear") { table.clearFilters() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
        .popover(item: $pendingColumn) { column in
            FilterEditor(column: column) { filter in
                table.upsert(filter: filter)
                pendingColumn = nil
            }
        }
    }

    @State private var pendingColumn: ColumnInfo?

    private func iconName(for kind: ColumnKind) -> String {
        switch kind {
        case .integer, .decimal, .floating: return "number"
        case .boolean: return "checkmark.square"
        case .date, .timestamp, .time: return "calendar"
        case .nested: return "list.bullet.indent"
        case .binary: return "doc.zipper"
        default: return "textformat"
        }
    }
}

private struct FilterChip: View {
    let filter: Filter
    @Environment(AppModel.self) private var app
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 4) {
            Text(filter.summary)
                .font(.caption)
                .lineLimit(1)
            Button {
                app.table.removeFilter(id: filter.id)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.16), in: Capsule())
        .onTapGesture { isEditing = true }
        .popover(isPresented: $isEditing) {
            FilterEditor(column: filter.column, existing: filter) { updated in
                app.table.upsert(filter: updated)
                isEditing = false
            }
        }
    }
}

/// The per-column filter popover.
///
/// Which controls appear depends on a distinct-value probe that runs *here*,
/// when the popover opens — not when a file is selected. Probing every column
/// up front would mean a scan per column just to look at a file.
struct FilterEditor: View {
    let column: ColumnInfo
    var existing: Filter?
    let onApply: (Filter) -> Void

    @Environment(AppModel.self) private var app

    @State private var affordance: FilterAffordance?
    @State private var probeError: String?
    @State private var isProbing = true

    @State private var selectedValues: Set<String> = []
    @State private var includeNull = false
    @State private var op: FilterOperator = .equal
    @State private var argument = ""
    @State private var secondArgument = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(column.name).font(.headline)
                Text(column.typeName).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            if isProbing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking values…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let probeError {
                Text(probeError).font(.callout).foregroundStyle(.red)
                comparisonControls
            } else if case .dropdown(let values, let hasNull, let sampled) = affordance {
                dropdownControls(values: values, hasNull: hasNull, sampled: sampled)
            } else {
                comparisonControls
            }

            Divider()

            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive) {
                        if let existing { app.table.removeFilter(id: existing.id) }
                    }
                }
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isApplyEnabled)
            }
        }
        .padding(12)
        .frame(width: 300)
        .task { await probe() }
    }

    // MARK: - Controls

    @ViewBuilder
    private func dropdownControls(values: [String], hasNull: Bool, sampled: Bool) -> some View {
        Text("Show rows where \(column.name) is any of:")
            .font(.callout)
            .foregroundStyle(.secondary)

        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(values, id: \.self) { value in
                    Toggle(isOn: binding(for: value)) {
                        Text(value.isEmpty ? "(empty)" : value)
                            .lineLimit(1)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                }
                if hasNull {
                    Toggle("NULL", isOn: $includeNull).toggleStyle(.checkbox).italic()
                }
            }
        }
        .frame(maxHeight: 220)

        if sampled {
            // The probe reads the head of the file to stay fast, so say so
            // rather than implying these are all the distinct values.
            Label("Values from the first 200,000 rows", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        Button("Use a comparison instead") {
            affordance = .comparison
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    @ViewBuilder
    private var comparisonControls: some View {
        Picker("", selection: $op) {
            ForEach(FilterOperator.available(for: column.kind)) { candidate in
                Text(candidate.rawValue).tag(candidate)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        if op.argumentCount >= 1 {
            TextField(op == .between ? "from" : "value", text: $argument)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
        if op.argumentCount >= 2 {
            TextField("to", text: $secondArgument)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func binding(for value: String) -> Binding<Bool> {
        Binding(
            get: { selectedValues.contains(value) },
            set: { isOn in
                if isOn { selectedValues.insert(value) } else { selectedValues.remove(value) }
            }
        )
    }

    // MARK: - Behaviour

    private var isApplyEnabled: Bool { draft()?.isComplete == true }

    private func draft() -> Filter? {
        let mode: Filter.Mode
        if case .dropdown = affordance {
            mode = .anyOf(selectedValues, includeNull: includeNull)
        } else {
            var arguments: [String] = []
            if op.argumentCount >= 1 { arguments.append(argument) }
            if op.argumentCount >= 2 { arguments.append(secondArgument) }
            mode = .comparison(op, arguments)
        }
        return Filter(id: existing?.id ?? UUID(), column: column, mode: mode)
    }

    private func apply() {
        guard let filter = draft(), filter.isComplete else { return }
        onApply(filter)
    }

    private func probe() async {
        // Restore the existing filter's state so reopening a chip edits it
        // rather than starting over.
        if let existing {
            switch existing.mode {
            case .anyOf(let values, let null):
                selectedValues = values
                includeNull = null
            case .comparison(let existingOp, let arguments):
                op = existingOp
                argument = arguments.first ?? ""
                secondArgument = arguments.count > 1 ? arguments[1] : ""
            }
        }
        if !FilterOperator.available(for: column.kind).contains(op) {
            op = FilterOperator.available(for: column.kind).first ?? .equal
        }

        do {
            let result = try await app.table.filterAffordance(for: column)
            // An existing comparison filter shouldn't be overridden by the
            // dropdown just because the column happens to be low cardinality.
            if let existing, case .comparison = existing.mode {
                affordance = .comparison
            } else {
                affordance = result
            }
        } catch {
            probeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            affordance = .comparison
        }
        isProbing = false
    }
}
