//
//  MainContentCoordinator+GridModels.swift
//  TablePro
//

import Combine
import Foundation
import TableProUtilities

// The Structure and Create Table owners answer which of their grids is on screen.
@MainActor
protocol ActiveGridModelProviding: AnyObject {
    var activeGridModel: DataGridModel? { get }
}

struct DataTabGridEntry {
    let model: DataGridModel
    let adapter: DataTabGridAdapter
    let store: QueryTabGridStateStore
    var lastUsed: Int
    var displayInputs: DataTabDisplayInputs?
}

// What decided a model's formatted text, which nothing invalidates while the grid is unmounted.
struct DataTabDisplayInputs: Equatable {
    let dateFormat: DateFormatOption
    let nullDisplay: String
    let smartValueDetection: Bool
    let systemTimeZoneGeneration: Int
    let overridesVersion: Int
}

extension MainContentCoordinator {
    // MARK: - Models

    func gridModel(forTab tabId: UUID) -> DataGridModel {
        displayStateClock &+= 1
        if let model = dataGridEntries[tabId]?.model {
            dataGridEntries[tabId]?.lastUsed = displayStateClock
            return model
        }
        let store = QueryTabGridStateStore(tabId: tabId, coordinator: self)
        let configuration = tabManager.tabs.first { $0.id == tabId }.map(gridConfiguration(for:)) ?? DataGridConfiguration()
        let model = DataGridModel(store: store, configuration: configuration, selectionSummary: selectionSummary)
        let adapter = DataTabGridAdapter(tabId: tabId, coordinator: self)
        adapter.attach(model)
        model.dataSource = adapter
        model.actions = adapter
        dataGridEntries[tabId] = DataTabGridEntry(
            model: model,
            adapter: adapter,
            store: store,
            lastUsed: displayStateClock,
            displayInputs: currentDisplayInputs
        )
        model.reloadRows()
        return model
    }

    func existingGridModel(forTab tabId: UUID) -> DataGridModel? {
        dataGridEntries[tabId]?.model
    }

    var selectedTabGridModel: DataGridModel? {
        tabManager.selectedTabId.flatMap(existingGridModel(forTab:))
    }

    // The one selection source: the data tab's model in Data, JSON and Map, the Structure or Create Table grid otherwise.
    var activeGridModel: DataGridModel? {
        guard let tab = tabManager.selectedTab else { return nil }
        switch GridSelectionOwner.resolve(tabType: tab.tabType, resultsViewMode: tab.display.resultsViewMode) {
        case .dataGrid:
            return gridModel(forTab: tab.id)
        case .schemaGrid:
            return activeGridModelProvider(for: tab)?.activeGridModel
        case .none:
            return nil
        }
    }

    var activeDataGridModel: DataGridModel? {
        guard let tab = tabManager.selectedTab,
              GridSelectionOwner.resolve(tabType: tab.tabType, resultsViewMode: tab.display.resultsViewMode) == .dataGrid
        else { return nil }
        return gridModel(forTab: tab.id)
    }

    func activeGridModelProvider(for tab: QueryTab) -> (any ActiveGridModelProviding)? {
        let owner: AnyObject? = tab.tabType == .createTable ? createTableDrafts[tab.id] : structureSessions[tab.id]
        return owner as? any ActiveGridModelProviding
    }

    func releaseGridModel(forTab tabId: UUID, persistingLayout: Bool = true) {
        guard let entry = dataGridEntries.removeValue(forKey: tabId) else { return }
        if persistingLayout {
            entry.store.flushPendingLayout()
        } else {
            entry.store.discardPendingLayout()
        }
        entry.model.discardEditing()
    }

    func releaseAllGridModels() {
        for tabId in Array(dataGridEntries.keys) {
            releaseGridModel(forTab: tabId)
        }
    }

    func flushColumnLayoutPersistence() {
        for entry in dataGridEntries.values {
            entry.store.flushPendingLayout()
        }
    }

    // MARK: - Row changes

    // Every replacement of a tab's rows reaches its model, mounted or not.
    func reloadGridModel(forTab tabId: UUID) {
        guard let model = existingGridModel(forTab: tabId) else { return }
        model.reloadRows()
        consumePendingColumnJump(forTab: tabId, contentReplaced: true)
    }

    func applyGridDelta(_ delta: Delta, forTab tabId: UUID) {
        guard let model = existingGridModel(forTab: tabId), delta != .none else { return }
        model.apply(delta)
        if delta == .columnsReplaced || delta == .fullReplace {
            consumePendingColumnJump(forTab: tabId, contentReplaced: delta == .fullReplace)
        }
    }

    // MARK: - Editing

    // The tab whose edits the shared change manager holds. A switch repoints it after it starts.
    var changeManagerTabId: UUID? {
        tabSwitchOutgoingTabId ?? tabManager.selectedTabId
    }

    @discardableResult
    func commitActiveGridEdit() -> Bool {
        guard let tab = tabManager.selectedTab else { return true }
        var committed = existingGridModel(forTab: tab.id)?.commitEditing() ?? true
        if let schemaModel = activeGridModelProvider(for: tab)?.activeGridModel {
            committed = schemaModel.commitEditing() && committed
        }
        // A run of typing in the structure inspector ends, so the command's undo step stands apart from it.
        activeStructureEditor?.commitPendingEdits()
        return committed
    }

    var isEditingActiveGrid: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        return existingGridModel(forTab: tab.id)?.isEditing == true
            || activeGridModelProvider(for: tab)?.activeGridModel?.isEditing == true
    }

    func observeChangeManagerForGridRepaint() -> AnyCancellable {
        changeManager.$reloadVersion
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectedTabGridModel?.repaintAllRows() }
    }

    // MARK: - Sort

    func requestSort(_ sort: SortState, forTab tabId: UUID) {
        guard tabManager.selectedTabId == tabId else { return }
        handleSortStateChanged(sort)
    }

    // MARK: - Configuration

    func gridConfiguration(for tab: QueryTab) -> DataGridConfiguration {
        let isSelected = tab.id == tabManager.selectedTabId
        let isEditable = isSelected && canEditActiveResult
        var configuration = DataGridConfiguration()
        configuration.primaryKeyColumns = tab.tableContext.primaryKeyColumns
        configuration.showRowNumbers = AppSettingsManager.shared.dataGrid.showRowNumbers
        configuration.appliesRowSortPreferences = true
        configuration.appliesRowCopyFormat = true
        configuration.supportsColumnSort = tab.tabType != .table || supportsColumnSort
        configuration.isEditable = isEditable
        configuration.editRefusalMessage = isSelected ? activeResultEditRefusal?.message : nil
        configuration.traits = DataGridEngineTraits(
            databaseType: connection.type,
            immutableColumns: Set(services.pluginManager.immutableColumns(for: connection.type)),
            usesTrueFalseBooleans: services.pluginManager.usesTrueFalseBooleans(for: connection.type),
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(connection.type),
            cellWriterSupport: changeManager.cellWriterSupport,
            supportsFieldRemoval: changeManager.supportsFieldRemoval,
            connectionScope: scope(for: tab)
        )
        configuration.commands = gridCommands(for: tab, isSelected: isSelected, isEditable: isEditable)
        return configuration
    }

    private func gridCommands(for tab: QueryTab, isSelected: Bool, isEditable: Bool) -> Set<DataGridCommand> {
        var commands: Set<DataGridCommand> = [
            .hideColumns, .showRowsAsJSON, .exportResults, .navigateForeignKey,
            .highlightValues, .displayAs, .freezeColumns, .valueFilter
        ]
        if isEditable {
            commands.formUnion([.addRow, .deleteRows, .undoDelete])
            // A duplicate copies values the result set alone cannot vouch for until the schema arrives.
            if tabSessionRegistry.existingTableRows(for: tab.id)?.hasAuthoritativeSchema == true {
                commands.insert(.duplicateRows)
            }
            if tab.tabType == .table { commands.insert(.pasteRows) }
        }
        if isSelected, canFilterRows { commands.insert(.filterWithColumn) }
        if tab.tableContext.tableName != nil { commands.insert(.copyAsSQL) }
        if tab.tabType == .table, !tab.tableContext.primaryKeyColumns.isEmpty { commands.insert(.loadUnloadedValues) }
        if findCoordinator.offersSearchAllRows(forTab: tab.id) { commands.insert(.searchAllRows) }
        if isSelected, canClearActiveQueryResults { commands.insert(.clearResults) }
        return commands
    }

    // MARK: - Display caches

    var currentDisplayInputs: DataTabDisplayInputs {
        let settings = AppSettingsManager.shared.dataGrid
        return DataTabDisplayInputs(
            dateFormat: settings.dateFormat,
            nullDisplay: settings.nullDisplay,
            smartValueDetection: settings.enableSmartValueDetection,
            systemTimeZoneGeneration: DateFormattingService.shared.systemTimeZoneGeneration,
            overridesVersion: ValueDisplayFormatService.shared.overridesVersion
        )
    }

    // Formatted text kept by an unmounted model goes stale when the settings it was formatted with move.
    func prepareGridModelForDisplay(forTab tabId: UUID) {
        let inputs = currentDisplayInputs
        guard let entry = dataGridEntries[tabId], entry.displayInputs != inputs else { return }
        entry.model.display.cache.removeAll()
        dataGridEntries[tabId]?.displayInputs = inputs
    }

    // The only memory a tab switch releases: formatted text, rebuilt per drawn cell. Rows stay until the user replaces them.
    func pruneGridDisplayCaches() {
        let budget = GridDisplayCacheBudget.unmountedGrids() + 1
        guard dataGridEntries.count > budget else { return }
        let ordered = dataGridEntries.sorted { $0.value.lastUsed > $1.value.lastUsed }
        for (tabId, entry) in ordered.dropFirst(budget) where !entry.model.isMounted {
            entry.model.display.cache.removeAll()
            dataGridEntries[tabId]?.displayInputs = nil
        }
    }
}

extension DataGridModel {
    var displayedRowIDs: [RowID]? {
        order.filteredIDs
    }
}
