//
//  FilterPanelView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct FilterPanelView: View {
    @Binding var state: TabFilterState
    let configuration: FilterPanelConfiguration
    let actions: any FilterPanelActions

    @State private var showSQLSheet = false
    @State private var showSettingsPopover = false
    @State private var generatedSQL = ""
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var focusedFilterId: UUID?

    private let maxFilterListHeight: CGFloat = 200
    @State private var filterRowsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            filterHeader

            Divider()

            if !state.filters.isEmpty {
                filterList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusSection()
        .onExitCommand {
            closePanelAndFocusGrid()
        }
        .onAppear {
            guard state.filters.isEmpty, !configuration.columns.isEmpty else {
                focusedFilterId = state.filters.last?.id
                return
            }
            focusedFilterId = addDefaultFilter(columns: configuration.columns)
        }
        .onChange(of: configuration.columns) { newColumns in
            guard state.filters.isEmpty, !newColumns.isEmpty, state.isVisible else { return }
            focusedFilterId = addDefaultFilter(columns: newColumns)
        }
        .sheet(isPresented: $showSQLSheet) {
            SQLPreviewSheet(sql: generatedSQL)
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 8) {
            if !state.filters.isEmpty {
                TristateCheckbox(
                    state: TristateCheckbox.State(allEnabled: state.allEnabledState),
                    action: toggleAllFiltersEnabled
                )
                .help(String(localized: "Enable or disable all filters"))
                .accessibilityLabel(String(localized: "Enable or disable all filters"))
            }

            Text("Filters")
                .font(.callout.weight(.medium))

            if state.filters.count > 1 {
                Picker("", selection: $state.filterLogicMode) {
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
                actions.clearAppliedFiltersAndReload()
                actions.focusGrid()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!state.hasAppliedFilters)
            .help(String(localized: "Clear applied filters without removing filter rows"))

            Button("Apply") {
                applyAllValidFilters()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(enabledValidFilterCount == 0 && !state.hasAppliedFilters)
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
                savePreset(named: newPresetName)
            }
        } message: {
            Text("Enter a name for this filter preset")
        }
    }

    private var filterOptionsMenu: some View {
        Menu {
            if let sqlPreview = configuration.sqlPreview {
                Button {
                    generatedSQL = sqlPreview.filterPreviewSQL()
                    showSQLSheet = true
                } label: {
                    Label(String(localized: "Preview Query"), systemImage: "text.magnifyingglass")
                }
                .disabled(state.filters.isEmpty)

                Divider()
            }

            if let presetStore = configuration.presetStore {
                presetItems(presetStore)

                Divider()
            }

            Button(role: .destructive) {
                actions.removeAllFiltersAndReload()
                actions.focusGrid()
            } label: {
                Label(String(localized: "Remove All Filters"), systemImage: "xmark.circle")
            }
            .disabled(state.filters.isEmpty)

            Divider()

            Button {
                showSettingsPopover.toggle()
            } label: {
                Label(String(localized: "Filter Settings…"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel(String(localized: "Filter options"))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(String(localized: "Filter options"))
        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
            FilterSettingsPopover()
        }
    }

    @ViewBuilder
    private func presetItems(_ presetStore: any FilterPresetStoring) -> some View {
        let presets = presetStore.loadAllPresets()
        if !presets.isEmpty {
            ForEach(presets) { preset in
                Button(action: { state.loadPreset(preset) }) {
                    HStack {
                        Text(preset.name)
                        if !presetColumnsMatch(preset) {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(String(localized: "Some columns in this preset don't exist in the current table"))
                                .accessibilityLabel(String(localized: "Some columns in this preset don't exist in the current table"))
                        }
                    }
                }
            }
            Divider()
        }

        Button("Save as Preset…") {
            newPresetName = ""
            showSavePresetAlert = true
        }
        .disabled(state.filters.isEmpty)

        if !presets.isEmpty {
            Menu("Delete Preset") {
                ForEach(presets) { preset in
                    Button(preset.name, role: .destructive) {
                        presetStore.deletePreset(preset)
                    }
                }
            }
        }
    }

    private var filterRows: some View {
        VStack(spacing: 0) {
            ForEach(state.filters) { filter in
                FilterRowView(
                    filter: filterBinding(for: filter),
                    columns: configuration.columns,
                    completions: completionItems,
                    caseMatching: configuration.caseMatching,
                    enumValuesByColumn: configuration.enumValuesByColumn,
                    rawSQLCompletionProvider: configuration.rawSQLCompletionProvider,
                    columnMenu: columnMenu,
                    fieldPaths: configuration.fieldPaths,
                    offersRawFilter: configuration.offersRawFilter,
                    rawFilterLabel: configuration.rawFilterLabel,
                    onAdd: {
                        focusedFilterId = addDefaultFilter(columns: configuration.columns)
                    },
                    onDuplicate: { duplicateFilter(filter) },
                    onRemove: { removeFilter(filter) },
                    onApply: { applySoloFilter(filter) },
                    onSubmit: { applyAllValidFilters() },
                    onCancel: { closePanelAndFocusGrid() },
                    isReorderEnabled: state.filters.count > 1,
                    canMoveUp: state.canMoveFilter(filter.id, direction: .up),
                    canMoveDown: state.canMoveFilter(filter.id, direction: .down),
                    onMoveUp: { state.moveFilter(filter.id, direction: .up) },
                    onMoveDown: { state.moveFilter(filter.id, direction: .down) },
                    onDropFilter: { draggedID in
                        state.moveFilter(draggedID, onto: filter.id)
                    },
                    focusedFilterId: $focusedFilterId
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var measuredFilterRows: some View {
        filterRows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { filterRowsHeight = $0 }
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
        state.filters.count { $0.isEnabled && $0.isValid }
    }

    private var completionItems: [String] {
        configuration.columns + configuration.valueCompletionKeywords
    }

    private var columnMenu: FilterColumnMenu {
        FilterColumnMenu.build(columns: configuration.columns, fieldPaths: configuration.fieldPaths)
    }

    private func filterBinding(for filter: TableFilter) -> Binding<TableFilter> {
        let stateBinding = $state
        return Binding(
            get: { stateBinding.wrappedValue.filters.first { $0.id == filter.id } ?? filter },
            set: { stateBinding.wrappedValue.updateFilter($0) }
        )
    }

    private func addDefaultFilter(columns: [String]) -> UUID {
        state.addFilter(
            settings: FilterSettingsStorage.shared.loadSettings(),
            columns: columns,
            primaryKeyColumn: configuration.primaryKeyColumn,
            offersRawFilter: configuration.offersRawFilter
        )
    }

    private func duplicateFilter(_ filter: TableFilter) {
        var next = state
        next.duplicateFilter(filter)
        state = next
        focusedFilterId = next.filters.last?.id
    }

    private func toggleAllFiltersEnabled() {
        let isEnabled = state.allEnabledState != true
        state.setAllFiltersEnabled(isEnabled)
    }

    private func removeFilter(_ filter: TableFilter) {
        var next = state
        let outcome = next.removeFilter(filter)
        state = next
        actions.reload(after: outcome)
        guard next.filters.isEmpty else { return }
        actions.closeFilterPanel()
        actions.focusGrid()
    }

    private func savePreset(named name: String) {
        guard !name.isEmpty, let presetStore = configuration.presetStore else { return }
        presetStore.savePreset(FilterPreset(name: name, filters: state.filters))
    }

    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let knownPaths = Set(configuration.fieldPaths.map(\.path))
        return preset.filters.map(\.columnName).allSatisfy { column in
            if configuration.offersRawFilter && column == TableFilter.rawSQLColumn { return true }
            return configuration.columns.contains(column) || knownPaths.contains(column)
        }
    }

    private func applyAllValidFilters() {
        actions.applyAllFilters()
        actions.focusGrid()
    }

    private func applySoloFilter(_ filter: TableFilter) {
        actions.applySoloFilter(filter)
        actions.focusGrid()
    }

    private func closePanelAndFocusGrid() {
        actions.closeFilterPanel()
        actions.focusGrid()
    }
}
