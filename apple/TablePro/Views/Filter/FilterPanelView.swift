import SwiftUI
import TableProPluginKit

struct FilterPanelView: View {
    @Binding var state: TabFilterState
    let configuration: FilterPanelConfiguration
    let actions: any FilterPanelActions

    @ObservedObject private var filterSettings = FilterSettingsStorage.shared
    @State private var columnMenuCache = FilterColumnMenuCache()
    @State private var showSQLSheet = false
    @State private var generatedSQL = ""
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var showRemoveAllConfirmation = false
    @State private var presetError: String?
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
        .paneBarBackground(Color(nsColor: .windowBackgroundColor))
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
            if let sqlPreview = configuration.sqlPreview {
                SQLPreviewSheet(sql: generatedSQL, databaseType: sqlPreview.filterPreviewDatabaseType)
            }
        }
        .confirmationDialog(
            String(localized: "Remove all filters?"),
            isPresented: $showRemoveAllConfirmation
        ) {
            Button(String(localized: "Remove All"), role: .destructive) {
                actions.removeAllFilters()
                actions.focusGrid()
            }
        } message: {
            Text("Every filter row for this table is deleted, and the table shows all rows.")
        }
        .alert(
            String(localized: "Could Not Save Presets"),
            isPresented: Binding(get: { presetError != nil }, set: { if !$0 { presetError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(presetError ?? "")
        }
    }

    private var filterHeader: some View {
        HStack(spacing: FilterRowView.spacing) {
            if !state.filters.isEmpty {
                // Holds the rows' drag handle column, so this checkbox sits over the rows' checkboxes.
                Color.clear
                    .frame(width: FilterRowDragHandle.gutterWidth, height: 1)
                    .accessibilityHidden(true)

                TristateCheckbox(
                    state: TristateCheckbox.State(allEnabled: state.allEnabledState),
                    action: toggleAllFiltersEnabled
                )
                .help(String(localized: "Check or uncheck all filters"))
                .accessibilityLabel(String(localized: "Check or uncheck all filters"))
            }

            Text("Filters")
                .font(.callout.weight(.medium))

            if state.filters.count > 1, configuration.offersMatchAny {
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

            Spacer(minLength: FilterRowView.spacing)

            if let statusText {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("filter-status")
            }

            filterOptionsMenu

            Button("Turn Off") {
                actions.turnOffFilters()
                actions.focusGrid()
            }
            .buttonStyle(.bordered)
            .disabled(!state.isFiltering)
            .help(String(localized: "Show every row again. The filters stay here."))

            Button("Apply") {
                actions.applyCheckedFilters()
                actions.focusGrid()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!state.canApplyCheckedRows)
            .help(String(localized: "Apply all checked filters (⌘↩)"))
        }
        .controlSize(.small)
        .padding(.horizontal, FilterRowView.horizontalInset)
        .padding(.vertical, 8)
        .paneBarBackground(Color(nsColor: .controlBackgroundColor))
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

    private var statusText: String? {
        switch state.status {
        case .notApplied: String(localized: "Not applied")
        case .changesNotApplied: String(localized: "Changes not applied")
        case .appliedAlone: String(localized: "Only one filter applied")
        case .applied, .empty: nil
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
                showRemoveAllConfirmation = true
            } label: {
                Label(String(localized: "Remove All Filters…"), systemImage: "trash")
            }
            .disabled(state.filters.isEmpty)

            Divider()

            Toggle(String(localized: "List Columns Alphabetically"), isOn: listsColumnsAlphabetically)

            Button {
                actions.openFilterSettings()
            } label: {
                Label(String(localized: "Filter Settings…"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel(String(localized: "Filter options"))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(String(localized: "Filter options"))
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
                        writePresets { try presetStore.deletePreset(preset) }
                    }
                }
            }
        }
    }

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.filters) { filter in
                FilterRowView(
                    filter: filterBinding(for: filter),
                    columnMenu: columnMenu,
                    completions: completionItems,
                    caseMatching: configuration.caseMatching,
                    enumValuesByColumn: configuration.enumValuesByColumn,
                    rawSQLCompletionProvider: configuration.rawSQLCompletionProvider,
                    fieldPaths: configuration.fieldPaths,
                    columnOrder: filterSettings.settings.columnOrder,
                    offersRawFilter: configuration.offersRawFilter,
                    rawFilterLabel: configuration.rawFilterLabel,
                    reservesElementScope: reservesElementScope,
                    isAppliedAlone: state.aloneFilterID == filter.id,
                    onAdd: {
                        focusedFilterId = addDefaultFilter(columns: configuration.columns, after: filter.id)
                    },
                    onDuplicate: { duplicateFilter(filter) },
                    onRemove: { removeFilter(filter) },
                    onApplyAlone: {
                        actions.applyFilterAlone(filter.id)
                        actions.focusGrid()
                    },
                    onApplyChecked: {
                        actions.applyCheckedFilters()
                        actions.focusGrid()
                    },
                    onSubmit: {
                        actions.applyFiltersInCurrentMode()
                        actions.focusGrid()
                    },
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

    private var reservesElementScope: Bool {
        state.filters.contains { filter in
            !filter.isRawSQL && FilterColumnMenu.elementScope(for: filter.columnName, in: configuration.fieldPaths) != nil
        }
    }

    private var completionItems: [String] {
        configuration.columns + configuration.valueCompletionKeywords
    }

    private var columnMenu: FilterColumnMenu {
        columnMenuCache.menu(
            columns: configuration.columns,
            fieldPaths: configuration.fieldPaths,
            order: filterSettings.settings.columnOrder
        )
    }

    private var listsColumnsAlphabetically: Binding<Bool> {
        Binding(
            get: { filterSettings.settings.columnOrder == .alphabetical },
            set: { isOn in
                var settings = filterSettings.settings
                settings.columnOrder = isOn ? .alphabetical : .table
                filterSettings.saveSettings(settings)
            }
        )
    }

    private func filterBinding(for filter: TableFilter) -> Binding<TableFilter> {
        let stateBinding = $state
        return Binding(
            get: { stateBinding.wrappedValue.filters.first { $0.id == filter.id } ?? filter },
            set: { stateBinding.wrappedValue.updateFilter($0) }
        )
    }

    private func addDefaultFilter(columns: [String], after anchorID: UUID? = nil) -> UUID {
        state.addFilter(
            settings: filterSettings.settings,
            columns: columns,
            primaryKeyColumn: configuration.primaryKeyColumn,
            offersRawFilter: configuration.offersRawFilter,
            after: anchorID
        )
    }

    private func duplicateFilter(_ filter: TableFilter) {
        var next = state
        let copyID = next.duplicateFilter(filter)
        state = next
        focusedFilterId = copyID
    }

    private func toggleAllFiltersEnabled() {
        let isEnabled = state.allEnabledState != true
        state.setAllFiltersEnabled(isEnabled)
    }

    // The last row closes the bar, so focus goes back to the grid with it.
    private func removeFilter(_ filter: TableFilter) {
        let removesLastRow = state.filters.count == 1
        actions.removeFilter(filter.id)
        if removesLastRow {
            actions.focusGrid()
        }
    }

    private func savePreset(named name: String) {
        guard !name.isEmpty, let presetStore = configuration.presetStore else { return }
        let preset = FilterPreset(name: name, filters: state.filters, logicMode: state.filterLogicMode)
        writePresets { try presetStore.savePreset(preset) }
    }

    private func writePresets(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let knownPaths = Set(configuration.fieldPaths.map(\.path))
        return preset.filters.allSatisfy { filter in
            if filter.isRawSQL { return configuration.offersRawFilter }
            return configuration.columns.contains(filter.columnName) || knownPaths.contains(filter.columnName)
        }
    }

    private func closePanelAndFocusGrid() {
        actions.closeFilterPanel()
        actions.focusGrid()
    }
}
