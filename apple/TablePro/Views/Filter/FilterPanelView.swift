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
    @State private var textModeRefusal: String?

    private let maxFilterListHeight: CGFloat = 200
    @State private var filterRowsHeight: CGFloat = 0

    /// Three lines of the value font, so a condition written over several lines stays readable.
    private let textConditionHeight: CGFloat = 60

    private var criteria: FilterCriteriaConfiguration? {
        configuration.criteria
    }

    /// Text mode only where the host offers it. Any other panel shows the rows, whatever the state
    /// says, so turning the setting off brings back the panel as it was.
    private var editMode: FilterEditMode {
        criteria?.offersTextMode == true ? state.effectiveEditMode : .builder
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeader

            Divider()

            if editMode == .text {
                textConditionEditor
            } else if !state.filters.isEmpty {
                filterList
            }

            if let criteria, let sortColumns = criteria.sortColumns {
                Divider()

                FilterSortSection(
                    state: $state,
                    columns: sortColumns,
                    appliedSort: criteria.appliedSort,
                    newSortDirection: criteria.newSortDirection
                )
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
            focusedFilterId = addStartingFilter(columns: configuration.columns)
        }
        .onChange(of: configuration.columns) { newColumns in
            guard state.filters.isEmpty, !newColumns.isEmpty, state.isVisible else { return }
            focusedFilterId = addStartingFilter(columns: newColumns)
        }
        .sheet(isPresented: $showSQLSheet) {
            if let sqlPreview = configuration.sqlPreview {
                SQLPreviewSheet(sql: generatedSQL, databaseType: sqlPreview.filterPreviewDatabaseType)
            }
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 8) {
            if editMode == .builder, !state.filters.isEmpty {
                TristateCheckbox(
                    state: TristateCheckbox.State(allEnabled: state.allEnabledState),
                    action: toggleAllFiltersEnabled
                )
                .help(String(localized: "Enable or disable all filters"))
                .accessibilityLabel(String(localized: "Enable or disable all filters"))
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

            Spacer()

            if let criteria, criteria.isEdited(state) {
                Text("Criteria Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "The rows on screen were fetched with different filters or sorting"))
            }

            filterOptionsMenu

            Button("Clear") {
                actions.clearAppliedFiltersAndReload()
                actions.focusGrid()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!state.hasAppliedFilters)
            .help(String(localized: "Clear applied filters without removing filter rows"))

            if let criteria {
                criteriaApplyButton(criteria)

                if criteria.offersTextMode {
                    editModePicker(criteria)
                }
            } else {
                Button("Apply") {
                    applyAllValidFilters()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(enabledValidFilterCount == 0 && !state.hasAppliedFilters)
                .help(String(localized: "Apply active filters (Cmd+Return)"))
            }
        }
        .padding(.horizontal, 12)
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

    /// Enabled whenever pressing it would change the rows, and whenever filters run, as the plain Apply is.
    @ViewBuilder
    private func criteriaApplyButton(_ criteria: FilterCriteriaConfiguration) -> some View {
        let changesRows = criteria.isEdited(state)
        let button = Button {
            applyAllValidFilters()
        } label: {
            if criteria.showsSort {
                Text("Apply Filter & Sort")
            } else {
                Text("Apply")
            }
        }
        .controlSize(.small)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!changesRows && enabledValidFilterCount == 0 && !state.hasAppliedFilters)
        .help(criteria.showsSort
            ? String(localized: "Apply the filters and the sort (Cmd+Return)")
            : String(localized: "Apply active filters (Cmd+Return)"))
        if criteria.applyIsProminent(for: state) {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func editModePicker(_ criteria: FilterCriteriaConfiguration) -> some View {
        Picker(String(localized: "Filter editing mode"), selection: editModeBinding(criteria)) {
            Text("Builder").tag(FilterEditMode.builder)
            Text("Text").tag(FilterEditMode.text)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
        .help(String(localized: "Edit the filter as rows or as one WHERE condition"))
        .alert(
            String(localized: "Can't Switch to Text"),
            isPresented: Binding(
                get: { textModeRefusal != nil },
                set: { if !$0 { textModeRefusal = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(textModeRefusal ?? "")
        }
    }

    private func editModeBinding(_ criteria: FilterCriteriaConfiguration) -> Binding<FilterEditMode> {
        Binding(
            get: { editMode },
            set: { switchEditMode(to: $0, criteria: criteria) }
        )
    }

    /// Builder to Text starts the editor from the enabled rows' WHERE condition; Text to Builder
    /// keeps the text as one raw row. Nothing is parsed, so neither direction can lose a condition.
    private func switchEditMode(to mode: FilterEditMode, criteria: FilterCriteriaConfiguration) {
        guard mode != editMode else { return }
        var next = state
        switch mode {
        case .text:
            let logicMode = configuration.offersMatchAny ? next.filterLogicMode : .and
            guard let condition = criteria.actions.filterConditionText(for: next.filters, logicMode: logicMode) else {
                textModeRefusal = String(localized: "These filters cannot be written as one condition for this database.")
                return
            }
            focusedFilterId = next.enterTextMode(condition: condition)
        case .builder:
            next.enterBuilderMode()
            focusedFilterId = next.filters.last?.id
        }
        state = next
    }

    @ViewBuilder
    private var textConditionEditor: some View {
        if let row = state.filters.first {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: "WHERE")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)

                FilterValueTextField(
                    text: textConditionBinding,
                    focusedId: $focusedFilterId,
                    identity: row.id,
                    placeholder: "e.g. id = 1",
                    completionSource: textCompletionSource,
                    allowsMultiLine: true,
                    onSubmit: { applyAllValidFilters() },
                    onCancel: { closePanelAndFocusGrid() }
                )
                .frame(height: textConditionHeight)
                .accessibilityLabel(String(localized: "WHERE clause"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var textConditionBinding: Binding<String> {
        let stateBinding = $state
        return Binding(
            get: { stateBinding.wrappedValue.textCondition },
            set: { text in
                var next = stateBinding.wrappedValue
                next.setTextCondition(text)
                stateBinding.wrappedValue = next
            }
        )
    }

    private var textCompletionSource: FilterCompletionSource {
        if let provider = configuration.rawSQLCompletionProvider {
            return .sqlTokens(provider)
        }
        return .staticValues(completionItems)
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

    /// The row an empty panel opens with, which the reader did not ask for by name.
    private func addStartingFilter(columns: [String]) -> UUID {
        state.addStartingFilter(
            settings: FilterSettingsStorage.shared.loadSettings(),
            columns: columns,
            primaryKeyColumn: configuration.primaryKeyColumn,
            offersRawFilter: configuration.offersRawFilter,
            isReplaceable: configuration.replacesUntouchedStartingRow
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
        let copyID = next.duplicateFilter(filter)
        state = next
        focusedFilterId = copyID
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
        return preset.filters.allSatisfy { filter in
            if filter.isRawSQL { return configuration.offersRawFilter }
            return configuration.columns.contains(filter.columnName) || knownPaths.contains(filter.columnName)
        }
    }

    /// Return in a row and Cmd-Return both run what the Apply button runs.
    private func applyAllValidFilters() {
        if let criteria {
            criteria.actions.applyFiltersAndSort()
        } else {
            actions.applyAllFilters()
        }
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
