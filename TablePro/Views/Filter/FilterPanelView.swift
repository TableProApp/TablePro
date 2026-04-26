//
//  FilterPanelView.swift
//  TablePro
//

import SwiftUI

struct FilterPanelView: View {
    @Bindable var filterState: FilterStateManager
    let columns: [String]
    let primaryKeyColumn: String?
    let databaseType: DatabaseType
    let onApply: ([TableFilter]) -> Void
    let onUnset: () -> Void

    @State private var showSQLSheet = false
    @State private var showSettingsPopover = false
    @State private var generatedSQL = ""
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var focusedFilterId: UUID?

    private let estimatedFilterRowHeight: CGFloat = 32
    private let maxFilterListHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            filterHeader

            Divider()

            if !filterState.filters.isEmpty {
                filterList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if filterState.filters.isEmpty && !columns.isEmpty {
                filterState.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
            }
            focusedFilterId = filterState.filters.last?.id
        }
        .onChange(of: columns) { _, newColumns in
            if filterState.filters.isEmpty && !newColumns.isEmpty && filterState.isVisible {
                filterState.addFilter(columns: newColumns, primaryKeyColumn: primaryKeyColumn)
                focusedFilterId = filterState.filters.last?.id
            }
        }
        .sheet(isPresented: $showSQLSheet) {
            SQLPreviewSheet(sql: generatedSQL)
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 8) {
            Text("Filters")
                .font(.callout.weight(.medium))

            if filterState.filters.count > 1 {
                Picker("", selection: $filterState.filterLogicMode) {
                    Text("AND").tag(FilterLogicMode.and)
                    Text("OR").tag(FilterLogicMode.or)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .accessibilityLabel(String(localized: "Filter logic mode"))
                .help(String(localized: "Match ALL filters (AND) or ANY filter (OR)"))
            }

            Spacer()

            filterOptionsMenu

            Button("Unset") {
                filterState.clearAll()
                onUnset()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!filterState.hasAppliedFilters)
            .help(String(localized: "Remove all filters and reload"))

            Button("Apply") {
                applyAllValidFilters()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(filterState.validFilterCount == 0)
            .help(String(localized: "Apply filters"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .alert(String(localized: "Save Filter Preset"), isPresented: $showSavePresetAlert) {
            TextField(String(localized: "Preset Name"), text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard !newPresetName.isEmpty else { return }
                filterState.saveAsPreset(name: newPresetName)
            }
        } message: {
            Text("Enter a name for this filter preset")
        }
    }

    private var filterOptionsMenu: some View {
        Menu {
            Button {
                generatedSQL = filterState.generatePreviewSQL(databaseType: databaseType)
                showSQLSheet = true
            } label: {
                Label(String(localized: "Preview Query"), systemImage: "text.magnifyingglass")
            }
            .disabled(filterState.filters.isEmpty)

            Divider()

            let presets = filterState.loadAllPresets()
            if !presets.isEmpty {
                ForEach(presets) { preset in
                    Button(action: { filterState.loadPreset(preset) }) {
                        HStack {
                            Text(preset.name)
                            if !presetColumnsMatch(preset) {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color(nsColor: .systemYellow))
                                    .help(String(localized: "Some columns in this preset don't exist in the current table"))
                            }
                        }
                    }
                }
                Divider()
            }

            Button("Save as Preset...") {
                newPresetName = ""
                showSavePresetAlert = true
            }
            .disabled(filterState.filters.isEmpty)

            if !presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presets) { preset in
                        Button(preset.name, role: .destructive) {
                            filterState.deletePreset(preset)
                        }
                    }
                }
            }

            Divider()

            Button {
                showSettingsPopover.toggle()
            } label: {
                Label(String(localized: "Filter Settings..."), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(.secondary)
        .accessibilityLabel(String(localized: "Filter options"))
        .help(String(localized: "Filter options"))
        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
            FilterSettingsPopover()
        }
    }

    private var filterRows: some View {
        VStack(spacing: 0) {
            ForEach(filterState.filters) { filter in
                FilterRowView(
                    filter: filterState.binding(for: filter),
                    columns: columns,
                    completions: completionItems(),
                    onAdd: {
                        filterState.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
                        focusedFilterId = filterState.filters.last?.id
                    },
                    onDuplicate: {
                        filterState.duplicateFilter(filter)
                        focusedFilterId = filterState.filters.last?.id
                    },
                    onRemove: {
                        let hadAppliedFilters = filterState.hasAppliedFilters
                        filterState.removeFilter(filter)
                        if filterState.filters.isEmpty {
                            if hadAppliedFilters {
                                filterState.clearAll()
                                onUnset()
                            } else {
                                filterState.close()
                            }
                        }
                    },
                    onSubmit: { applyAllValidFilters() },
                    focusedFilterId: $focusedFilterId
                )
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var filterList: some View {
        let estimatedHeight = CGFloat(filterState.filters.count) * estimatedFilterRowHeight + 8
        if estimatedHeight > maxFilterListHeight {
            ScrollView {
                filterRows
            }
            .frame(maxHeight: maxFilterListHeight)
        } else {
            filterRows
        }
    }

    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let presetColumns = preset.filters.map(\.columnName).filter { $0 != TableFilter.rawSQLColumn }
        return presetColumns.allSatisfy { columns.contains($0) }
    }

    private func applyAllValidFilters() {
        filterState.applyAllFilters()
        onApply(filterState.appliedFilters)
    }

    private func completionItems() -> [String] {
        let langName = PluginManager.shared.queryLanguageName(for: databaseType)
        let isSQLDialect = langName == "SQL" || langName == "CQL" || langName == "PartiQL"
        let sqlKeywords = [
            "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
            "IS NULL", "IS NOT NULL", "EXISTS",
            "CASE", "WHEN", "THEN", "ELSE", "END",
        ]
        return isSQLDialect ? columns + sqlKeywords : columns
    }
}

#Preview("Filter Panel") {
    FilterPanelView(
        filterState: {
            let state = FilterStateManager()
            Task { @MainActor in
                state.filters = [
                    TableFilter(columnName: "name", filterOperator: .contains, value: "John"),
                    TableFilter(columnName: "age", filterOperator: .greaterThan, value: "18")
                ]
            }
            return state
        }(),
        columns: ["id", "name", "age", "email"],
        primaryKeyColumn: "id",
        databaseType: .mysql,
        onApply: { _ in },
        onUnset: { }
    )
    .frame(width: 600)
}
