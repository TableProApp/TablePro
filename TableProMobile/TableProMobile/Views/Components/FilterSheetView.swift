import SwiftUI
import TableProModels

struct FilterSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: [TableFilter]
    @Binding var logicMode: FilterLogicMode
    let columns: [ColumnInfo]
    let onApply: () -> Void
    let onClear: () -> Void

    @State private var draft: [TableFilter] = []
    @State private var draftLogicMode: FilterLogicMode = .and
    @State private var showClearConfirmation = false

    private var hasValidFilters: Bool {
        draft.contains { $0.isEnabled && $0.isValid }
    }

    private func bindingForFilter(_ id: UUID) -> Binding<TableFilter>? {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return nil }
        return $draft[index]
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.count > 1 {
                    Section {
                        Picker("Logic", selection: $draftLogicMode) {
                            Text("AND").tag(FilterLogicMode.and)
                            Text("OR").tag(FilterLogicMode.or)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                ForEach(draft) { filter in
                    if let binding = bindingForFilter(filter.id) {
                        Section {
                            Picker("Column", selection: binding.columnName) {
                                ForEach(columns, id: \.name) { col in
                                    Text(col.name).tag(col.name)
                                }
                            }

                            Picker("Operator", selection: binding.filterOperator) {
                                ForEach(FilterOperator.allCases, id: \.self) { op in
                                    Text(op.displayName).tag(op)
                                }
                            }

                            if filter.filterOperator.needsValue {
                                TextField("Value", text: binding.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            if filter.filterOperator == .between {
                                TextField("Second value", text: binding.secondValue)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    draft.remove(atOffsets: indexSet)
                }

                Section {
                    Button {
                        draft.append(TableFilter(columnName: columns.first?.name ?? ""))
                    } label: {
                        Label("Add Filter", systemImage: "plus.circle")
                    }
                }

                if !draft.isEmpty {
                    Section {
                        Button("Clear All Filters", role: .destructive) {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filters = draft
                        logicMode = draftLogicMode
                        onApply()
                        dismiss()
                    }
                    .disabled(!hasValidFilters)
                }
            }
            .onAppear {
                draft = filters
                draftLogicMode = logicMode
            }
            .confirmationDialog(
                String(localized: "Clear All Filters"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Clear All"), role: .destructive) {
                    filters.removeAll()
                    logicMode = .and
                    onClear()
                    dismiss()
                }
            } message: {
                Text("All filter conditions will be removed.")
            }
        }
    }
}

// MARK: - Filter Operator Display

extension FilterOperator {
    var displayName: String {
        switch self {
        case .equal: return "equals"
        case .notEqual: return "not equals"
        case .greaterThan: return "greater than"
        case .greaterThanOrEqual: return "≥"
        case .lessThan: return "less than"
        case .lessThanOrEqual: return "≤"
        case .like: return "like"
        case .notLike: return "not like"
        case .isNull: return "is null"
        case .isNotNull: return "is not null"
        case .in: return "in"
        case .notIn: return "not in"
        case .between: return "between"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        }
    }

    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull: return false
        default: return true
        }
    }
}
