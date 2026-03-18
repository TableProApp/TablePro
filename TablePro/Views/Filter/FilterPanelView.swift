//
//  FilterPanelView.swift
//  TablePro
//
//  Filter panel for table data filtering.
//  Child views extracted to separate files for maintainability.
//

import SwiftUI

/// Filter panel for table data filtering
struct FilterPanelView: View {
    @Bindable var filterState: FilterStateManager
    let columns: [String]
    let primaryKeyColumn: String?
    let databaseType: DatabaseType
    let onApply: ([TableFilter]) -> Void
    let onUnset: () -> Void
    let onQuickSearch: ((String) -> Void)?

    @State private var showSQLSheet = false
    @State private var showSettingsPopover = false
    @State private var generatedSQL = ""
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var savedPresets: [FilterPreset] = []

    var body: some View {
        VStack(spacing: 0) {
            filterHeader

            Divider()
                .foregroundStyle(Color(nsColor: .separatorColor))

            // Quick Search field (always visible)
            QuickSearchField(
                searchText: $filterState.quickSearchText,
                shouldFocus: $filterState.shouldFocusQuickSearch,
                onSubmit: { onQuickSearch?(filterState.quickSearchText) },
                onClear: { filterState.clearQuickSearch() }
            )
            Divider()
                .foregroundStyle(Color(nsColor: .separatorColor))

            // Filter rows (only when filters exist)
            if !filterState.filters.isEmpty {
                filterList
            }

            Divider()
                .foregroundStyle(Color(nsColor: .separatorColor))

            filterFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSQLSheet) {
            SQLPreviewSheet(sql: generatedSQL, tableName: "", databaseType: databaseType)
        }
    }

    // MARK: - Header

    private var filterHeader: some View {
        HStack(spacing: 8) {
            Text("Filters")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .medium))

            if filterState.hasAppliedFilters {
                Text("(\(filterState.appliedFilters.count) active)")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // AND/OR Logic Toggle
            Picker("", selection: $filterState.filterLogicMode) {
                Text("AND").tag(FilterLogicMode.and)
                Text("OR").tag(FilterLogicMode.or)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
            .accessibilityLabel(String(localized: "Filter logic mode"))
            .help("Match ALL filters (AND) or ANY filter (OR)")

            presetsMenu

            // Settings button
            Button(action: { showSettingsPopover.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.small))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "Filter settings"))
            .help("Filter Settings")
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                FilterSettingsPopover()
            }

            // Add filter button
            Button(action: {
                filterState.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
            }) {
                Image(systemName: "plus")
                    .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.small))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .accessibilityLabel(String(localized: "Add filter"))
            .help("Add Filter (Cmd+Shift+F)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xs)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { filterState.focusedFilterId = nil }
        .alert("Save Filter Preset", isPresented: $showSavePresetAlert) {
            TextField("Preset Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if !newPresetName.isEmpty {
                    filterState.saveAsPreset(name: newPresetName)
                    loadPresets()
                }
            }
        } message: {
            Text("Enter a name for this filter preset")
        }
    }

    // MARK: - Presets Menu

    private var presetsMenu: some View {
        Menu {
            if !savedPresets.isEmpty {
                ForEach(savedPresets) { preset in
                    Button(action: { filterState.loadPreset(preset) }) {
                        HStack {
                            Text(preset.name)
                            if !presetColumnsMatch(preset) {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
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

            if !savedPresets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(savedPresets) { preset in
                        Button(preset.name, role: .destructive) {
                            filterState.deletePreset(preset)
                            loadPresets()
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "folder")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.small))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(String(localized: "Filter presets"))
        .help("Save and load filter presets")
        .onAppear {
            loadPresets()
        }
    }

    // MARK: - Filter List

    private var filterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach($filterState.filters) { $filter in
                        FilterRowView(
                            filter: $filter,
                            columns: columns,
                            isFocused: filterState.focusedFilterId == filter.id,
                            onDuplicate: { filterState.duplicateFilter(filter) },
                            onRemove: { filterState.removeFilter(filter) },
                            onApply: { applySingleFilter(filter) },
                            onFocus: { filterState.focusedFilterId = filter.id }
                        )
                        .id(filter.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: min(CGFloat(filterState.filters.count) * 42 + 8, 200))
            .onChange(of: filterState.focusedFilterId) { _, newFocusedId in
                if let focusedId = newFocusedId {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(focusedId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var filterFooter: some View {
        HStack(spacing: 8) {
            Toggle("Select All", isOn: selectAllBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.secondary)
                .disabled(filterState.filters.isEmpty)

            Spacer()

            Button("Unset") {
                filterState.clearAppliedFilters()
                onUnset()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!filterState.hasAppliedFilters)

            Button(PluginManager.shared.queryLanguageName(for: databaseType)) {
                generatedSQL = filterState.generatePreviewSQL(databaseType: databaseType)
                showSQLSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(filterState.filters.isEmpty)

            Button("Apply All") {
                applySelectedFilters()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!filterState.hasSelectedFilters)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { filterState.focusedFilterId = nil }
    }

    // MARK: - Helpers

    private var selectAllBinding: Binding<Bool> {
        Binding(
            get: { filterState.allFiltersSelected },
            set: { filterState.selectAll($0) }
        )
    }

    /// Check if all columns referenced in a preset exist in the current table's columns
    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let presetColumns = preset.filters.map(\.columnName).filter { $0 != TableFilter.rawSQLColumn }
        return presetColumns.allSatisfy { columns.contains($0) }
    }

    private func applySingleFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        filterState.applySingleFilter(filter)
        onApply([filter])
    }

    private func applySelectedFilters() {
        filterState.applySelectedFilters()
        onApply(filterState.appliedFilters)
    }

    private func loadPresets() {
        savedPresets = filterState.loadAllPresets()
    }
}

// MARK: - Preview

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
        onUnset: { },
        onQuickSearch: { _ in }
    )
    .frame(width: 600)
}
