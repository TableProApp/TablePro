import SwiftUI
import TableProCoreTypes
import TableProModels
import TableProPluginKit
import TableProQuery

struct FilterSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: [TableFilter]
    @Binding var logicMode: FilterLogicMode
    let columns: [ColumnInfo]
    let databaseType: DatabaseType
    let onApply: () -> Void
    let onClear: () -> Void

    @State private var draft: [TableFilter] = []
    @State private var draftLogicMode: FilterLogicMode = .and
    @State private var showClearConfirmation = false

    private var hasValidFilters: Bool {
        draft.contains { $0.isEnabled && $0.isValid }
    }

    private var isCaseSensitivityAdjustable: Bool {
        PluginSQLCaseFolding.isAdjustable(style: SQLBuilder.caseSensitivityStyle(for: databaseType))
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

                            if filter.filterOperator.supportsCaseSensitivity, isCaseSensitivityAdjustable {
                                Toggle("Match Case", isOn: binding.isCaseSensitive)
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
                    CancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Apply") {
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
    var displayName: LocalizedStringResource {
        switch self {
        case .equal: return LocalizedStringResource("equals")
        case .notEqual: return LocalizedStringResource("not equals")
        case .greaterThan: return LocalizedStringResource("greater than")
        case .greaterThanOrEqual: return LocalizedStringResource("≥")
        case .lessThan: return LocalizedStringResource("less than")
        case .lessThanOrEqual: return LocalizedStringResource("≤")
        case .like: return LocalizedStringResource("like")
        case .notLike: return LocalizedStringResource("not like")
        case .isNull: return LocalizedStringResource("is null")
        case .isNotNull: return LocalizedStringResource("is not null")
        case .in: return LocalizedStringResource("in")
        case .notIn: return LocalizedStringResource("not in")
        case .between: return LocalizedStringResource("between")
        case .contains: return LocalizedStringResource("contains")
        case .startsWith: return LocalizedStringResource("starts with")
        case .endsWith: return LocalizedStringResource("ends with")
        }
    }

    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull: return false
        default: return true
        }
    }
}
