//
//  FilterPanelView.swift
//  TablePro
//

import SwiftUI

struct FilterPanelView: View {
    let coordinator: MainContentCoordinator
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

    private var filterState: TabFilterState {
        coordinator.selectedTabFilterState
    }

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
                coordinator.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
            }
            focusedFilterId = filterState.filters.last?.id
        }
        .onChange(of: columns) { _, newColumns in
            if filterState.filters.isEmpty && !newColumns.isEmpty && filterState.isVisible {
                coordinator.addFilter(columns: newColumns, primaryKeyColumn: primaryKeyColumn)
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
                Picker("", selection: coordinator.filterLogicModeBinding()) {
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
                coordinator.clearFilterState()
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
            .disabled(validFilterCount == 0)
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
                coordinator.saveFilterPreset(name: newPresetName)
            }
        } message: {
            Text("Enter a name for this filter preset")
        }
    }

    private var filterOptionsMenu: some View {
        Menu {
            Button {
                generatedSQL = coordinator.generateFilterPreviewSQL(databaseType: databaseType)
                showSQLSheet = true
            } label: {
                Label(String(localized: "Preview Query"), systemImage: "text.magnifyingglass")
            }
            .disabled(filterState.filters.isEmpty)

            Divider()

            let presets = coordinator.loadAllFilterPresets()
            if !presets.isEmpty {
                ForEach(presets) { preset in
                    Button(action: { coordinator.loadFilterPreset(preset) }) {
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
                            coordinator.deleteFilterPreset(preset)
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
                    filter: coordinator.filterBinding(for: filter),
                    columns: columns,
                    completions: completionItems(),
                    onAdd: {
                        coordinator.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
                        focusedFilterId = filterState.filters.last?.id
                    },
                    onDuplicate: {
                        coordinator.duplicateFilter(filter)
                        focusedFilterId = filterState.filters.last?.id
                    },
                    onRemove: {
                        let hadAppliedFilters = filterState.hasAppliedFilters
                        coordinator.removeFilter(filter)
                        if filterState.filters.isEmpty {
                            if hadAppliedFilters {
                                coordinator.clearFilterState()
                                onUnset()
                            } else {
                                coordinator.closeFilterPanel()
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

    private var validFilterCount: Int {
        filterState.filters.count(where: \.isValid)
    }

    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let presetColumns = preset.filters.map(\.columnName).filter { $0 != TableFilter.rawSQLColumn }
        return presetColumns.allSatisfy { columns.contains($0) }
    }

    private func applyAllValidFilters() {
        coordinator.applyAllFilters()
        onApply(coordinator.selectedTabFilterState.appliedFilters)
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
