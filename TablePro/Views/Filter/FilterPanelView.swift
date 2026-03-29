//
//  FilterPanelView.swift
//  TablePro
//
//  Filter panel for table data filtering.
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
    @State private var savedPresets: [FilterPreset] = []

    private let filterRowHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            filterHeader

            Divider()
                .foregroundStyle(Color(nsColor: .separatorColor))

            if !filterState.filters.isEmpty {
                filterList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if filterState.filters.isEmpty && !columns.isEmpty {
                filterState.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
            }
        }
        .onChange(of: columns) { _, newColumns in
            if filterState.filters.isEmpty && !newColumns.isEmpty && filterState.isVisible {
                filterState.addFilter(columns: newColumns, primaryKeyColumn: primaryKeyColumn)
            }
        }
        .sheet(isPresented: $showSQLSheet) {
            SQLPreviewSheet(sql: generatedSQL, tableName: "", databaseType: databaseType)
        }
    }

    // MARK: - Header

    private var filterHeader: some View {
        HStack(spacing: 8) {
            Text("Filters")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .medium))

            if filterState.filters.count > 1 {
                Picker("", selection: $filterState.filterLogicMode) {
                    Text("AND").tag(FilterLogicMode.and)
                    Text("OR").tag(FilterLogicMode.or)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .accessibilityLabel(String(localized: "Filter logic mode"))
                .help("Match ALL filters (AND) or ANY filter (OR)")
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
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xs)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
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

    // MARK: - Options Menu

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

            if !savedPresets.isEmpty {
                ForEach(savedPresets) { preset in
                    Button(action: { filterState.loadPreset(preset) }) {
                        HStack {
                            Text(preset.name)
                            if !presetColumnsMatch(preset) {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color(nsColor: .systemYellow))
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

            Divider()

            Button {
                showSettingsPopover.toggle()
            } label: {
                Label(String(localized: "Filter Settings..."), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.small))
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(.secondary)
        .accessibilityLabel(String(localized: "Filter options"))
        .help(String(localized: "Filter options"))
        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
            FilterSettingsPopover()
        }
        .onAppear {
            loadPresets()
        }
    }

    // MARK: - Filter List

    private var filterRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(filterState.filters) { filter in
                FilterRowView(
                    filter: filterState.binding(for: filter),
                    columns: columns,
                    onAdd: { filterState.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn) },
                    onDuplicate: { filterState.duplicateFilter(filter) },
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
                    shouldFocus: filter.id == filterState.filters.last?.id
                )
            }
        }
        .padding(.vertical, 4)
    }

    private let maxFilterListHeight: CGFloat = 200

    @ViewBuilder
    private var filterList: some View {
        let contentHeight = CGFloat(filterState.filters.count) * filterRowHeight + 8
        if contentHeight > maxFilterListHeight {
            ScrollView {
                filterRows
            }
            .frame(height: maxFilterListHeight)
        } else {
            filterRows
        }
    }

    // MARK: - Helpers

    private func presetColumnsMatch(_ preset: FilterPreset) -> Bool {
        let presetColumns = preset.filters.map(\.columnName).filter { $0 != TableFilter.rawSQLColumn }
        return presetColumns.allSatisfy { columns.contains($0) }
    }

    private func applyAllValidFilters() {
        filterState.applyAllFilters()
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
        onUnset: { }
    )
    .frame(width: 600)
}
