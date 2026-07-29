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
    let enumValuesByColumn: [String: [String]]
    let onApply: ([TableFilter]) -> Void
    let onUnset: () -> Void

    @State private var showSQLSheet = false
    @State private var showSettingsPopover = false
    @State private var generatedSQL = ""
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var focusedFilterId: UUID?
    @State private var rawSQLCompletionProvider: RawSQLFilterCompletionProvider?

    private let maxFilterListHeight: CGFloat = 200
    @State private var filterRowsHeight: CGFloat = 0

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
        .focusSection()
        .onExitCommand {
            closePanelAndFocusGrid()
        }
        .onAppear {
            if filterState.filters.isEmpty && !columns.isEmpty {
                coordinator.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
            }
            focusedFilterId = filterState.filters.last?.id
            refreshRawSQLCompletionProvider()
        }
        .onChange(of: columns) { _, newColumns in
            if filterState.filters.isEmpty && !newColumns.isEmpty && filterState.isVisible {
                coordinator.addFilter(columns: newColumns, primaryKeyColumn: primaryKeyColumn)
                focusedFilterId = filterState.filters.last?.id
            }
            refreshRawSQLCompletionProvider()
        }
        .onChange(of: coordinator.currentTableName) { _, _ in
            refreshRawSQLCompletionProvider()
        }
        .sheet(isPresented: $showSQLSheet) {
            SQLPreviewSheet(sql: generatedSQL)
        }
        .onPreferenceChange(FilterRowsHeightKey.self) { filterRowsHeight = $0 }
    }

    private func toggleAllFiltersEnabled() {
        let newState = filterState.allEnabledState != true
        for filter in filterState.filters {
            var updated = filter
            updated.isEnabled = newState
            coordinator.updateFilter(updated)
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 8) {
            if !filterState.filters.isEmpty {
                TristateCheckbox(
                    state: TristateCheckbox.State(allEnabled: filterState.allEnabledState),
                    action: toggleAllFiltersEnabled
                )
                .help(String(localized: "Enable or disable all filters"))
                .accessibilityLabel(String(localized: "Enable or disable all filters"))
            }

            Text("Filters")
                .font(.callout.weight(.medium))

            if filterState.filters.count > 1 {
                Picker("", selection: coordinator.filterLogicModeBinding()) {
                    Text("Match all").tag(FilterLogicMode.and)
                    Text("Match any").tag(FilterLogicMode.or)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .labelsHidden()
                .accessibilityLabel(String(localized: "Filter logic mode"))
                .help(String(localized: "Match all filters or any filter"))
            }

            Spacer()

            filterOptionsMenu

            Button("Clear") {
                coordinator.clearAppliedFilters()
                onUnset()
                coordinator.focusActiveGrid()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!filterState.hasAppliedFilters)
            .help(String(localized: "Clear applied filters without removing filter rows"))

            Button("Apply") {
                applyAllValidFilters()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(enabledValidFilterCount == 0 && !filterState.hasAppliedFilters)
            .help(String(localized: "Apply active filters (Cmd+Return)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .alert(String(localized: "Save Filter Preset"), isPresented: $showSavePresetAlert) {
            TextField(String(localized: "Preset Name"), text: $newPresetName)
                .autocorrectionDisabled(true)
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
                                    .foregroundStyle(.yellow)
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

            Button(role: .destructive) {
                coordinator.clearFilterState()
                onUnset()
                coordinator.focusActiveGrid()
            } label: {
                Label(String(localized: "Remove All Filters"), systemImage: "xmark.circle")
            }
            .disabled(filterState.filters.isEmpty)

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
                    enumValuesByColumn: enumValuesByColumn,
                    rawSQLCompletionProvider: rawSQLCompletionProvider,
                    onAdd: {
                        coordinator.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
                        focusedFilterId = filterState.filters.last?.id
                    },
                    onDuplicate: {
                        coordinator.duplicateFilter(filter)
                        focusedFilterId = filterState.filters.last?.id
                    },
                    onRemove: {
                        coordinator.removeFilterAndReload(filter)
                        if filterState.filters.isEmpty {
                            coordinator.closeFilterPanel()
                            coordinator.focusActiveGrid()
                        }
                    },
                    onApply: { applySoloFilter(filter) },
                    onSubmit: { applyAllValidFilters() },
                    onCancel: { closePanelAndFocusGrid() },
                    focusedFilterId: $focusedFilterId
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var measuredFilterRows: some View {
        filterRows.background(
            GeometryReader { proxy in
                Color.clear.preference(key: FilterRowsHeightKey.self, value: proxy.size.height)
            }
        )
    }

    @ViewBuilder
    private var filterList: some View {
        if filterRowsHeight > maxFilterListHeight {
            ScrollView {
                measuredFilterRows
            }
            .frame(height: maxFilterListHeight)
        } else {
            measuredFilterRows
        }
    }

    private var enabledValidFilterCount: Int {
        filterState.filters.count { $0.isEnabled && $0.isValid }
    }

    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let presetColumns = preset.filters.map(\.columnName).filter { $0 != TableFilter.rawSQLColumn }
        return presetColumns.allSatisfy { columns.contains($0) }
    }

    private func applyAllValidFilters() {
        coordinator.applyAllFilters()
        onApply(coordinator.selectedTabFilterState.appliedFilters)
        coordinator.focusActiveGrid()
    }

    private func applySoloFilter(_ filter: TableFilter) {
        coordinator.applySoloFilter(filter)
        onApply(coordinator.selectedTabFilterState.appliedFilters)
        coordinator.focusActiveGrid()
    }

    private func closePanelAndFocusGrid() {
        coordinator.closeFilterPanel()
        coordinator.focusActiveGrid()
    }

    private var isSQLDialect: Bool {
        PluginManager.shared.sqlDialect(for: databaseType) != nil
    }

    private func completionItems() -> [String] {
        let sqlKeywords = [
            "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
            "IS NULL", "IS NOT NULL", "EXISTS",
            "CASE", "WHEN", "THEN", "ELSE", "END",
        ]
        return isSQLDialect ? columns + sqlKeywords : columns
    }

    private func refreshRawSQLCompletionProvider() {
        guard isSQLDialect, let tableName = coordinator.currentTableName else {
            rawSQLCompletionProvider = nil
            return
        }
        let schemaProvider = SchemaProviderRegistry.shared.getOrCreate(for: coordinator.connection.id)
        rawSQLCompletionProvider = RawSQLFilterCompletionProvider(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            tableName: tableName
        )
    }
}

private struct FilterRowsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
