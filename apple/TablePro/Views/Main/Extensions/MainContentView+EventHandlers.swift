//
//  MainContentView+EventHandlers.swift
//  TablePro
//

import os
import SwiftUI
import TableProPluginKit

extension MainContentView {
    // MARK: - Event Handlers

    func handleTabSelectionChange(from oldTabId: UUID?, to newTabId: UUID?) {
        guard !coordinator.isTearingDown else {
            MainContentView.lifecycleLogger.debug("[switch] handleTabSelectionChange SKIPPED (tearingDown) connId=\(coordinator.connectionId, privacy: .public)")
            return
        }
        let t0 = Date()
        coordinator.handleTabChange(
            from: oldTabId,
            to: newTabId,
            tabs: tabManager.tabs
        )
        let t1 = Date()

        updateWindowTitleAndFileState()
        let t2 = Date()

        // In a background window this is usually a side effect (a close refocusing a neighbour); it re-marks once it is key.
        if coordinator.isKeyWindow {
            coordinator.syncSidebarObjectSelection()
        }
        let t3 = Date()

        guard !coordinator.isTearingDown else { return }
        let aggregated = MainContentCoordinator.aggregatedTabs(for: coordinator.connectionId)
        coordinator.persistence.saveNow(
            tabs: aggregated,
            selectedTabId: newTabId
        )
        MainContentView.lifecycleLogger.debug(
            "[switch] handleTabSelectionChange breakdown: tabChange=\(Int(t1.timeIntervalSince(t0) * 1_000))ms windowTitle=\(Int(t2.timeIntervalSince(t1) * 1_000))ms sidebarSync=\(Int(t3.timeIntervalSince(t2) * 1_000))ms persistSave=\(Int(Date().timeIntervalSince(t3) * 1_000))ms"
        )
    }

    func handleStructureChange() {
        guard !coordinator.isTearingDown else {
            MainContentView.lifecycleLogger.debug("[switch] handleStructureChange SKIPPED (tearingDown) tabCount=\(tabManager.tabs.count) connId=\(coordinator.connectionId, privacy: .public)")
            return
        }
        let t0 = Date()

        if !coordinator.isHandlingTabSwitch {
            updateWindowTitleAndFileState()
        }

        guard !coordinator.isUpdatingColumnLayout else { return }

        if let tab = tabManager.selectedTab, tab.isPreview, tab.hasUserInteraction {
            coordinator.promotePreviewTab()
        }

        coordinator.persistence.saveAggregated()
        MainContentView.lifecycleLogger.debug(
            "[switch] handleStructureChange tabCount=\(tabManager.tabs.count) ms=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

    func handleColumnsChange(newColumns: [String]?) {
        // Skip during tab switch: handleTabChange already describes the incoming tab's result to its edits
        guard !coordinator.isHandlingTabSwitch else { return }

        if let newColumns = newColumns {
            coordinator.pruneHiddenColumns(currentColumns: newColumns)
        }

        guard let newColumns = newColumns, !newColumns.isEmpty,
            let tab = tabManager.selectedTab,
            !changeManager.hasChanges
        else { return }

        let columnsChanged = changeManager.columns != newColumns
        let tableChanged = changeManager.tableName != (tab.tableContext.tableName ?? "")

        guard columnsChanged || tableChanged else { return }

        let rows = coordinator.tabSessionRegistry.tableRows(for: tab.id)
        changeManager.configureForTable(
            tableName: tab.tableContext.tableName ?? "",
            schemaName: tab.tableContext.schemaName,
            columns: newColumns,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type,
            generatedColumns: rows.generatedColumns,
            rowMatchPolicy: rows.rowMatchPolicy,
            columnTypeNames: rows.columnTypeNames
        )
    }

    func handleTableSelectionChange(
        from oldTables: Set<DatabaseTreeTableRef>, to newTables: Set<DatabaseTreeTableRef>
    ) {
        let action = TableSelectionAction.resolve(
            oldTables: oldTables,
            newTables: newTables,
            selectedRowCount: coordinator.windowSidebarState.selectedRowCount
        )

        guard case .navigate(let ref) = action else {
            return
        }
        let table = ref.table

        guard coordinator.isKeyWindow else {
            return
        }

        let result = SidebarNavigationResult.resolve(
            clickedTableName: table.name,
            currentTabTableName: tabManager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !tabManager.tabs.isEmpty,
            isActiveTabReusable: coordinator.isActiveTabReusable
        )

        MainContentView.lifecycleLogger.debug(
            """
            [tableload] sidebarSelection table=\(table.name, privacy: .private(mask: .hash)) \
            decision=\(String(describing: result), privacy: .public) \
            currentTab=\(tabManager.selectedTab?.tableContext.tableName ?? "none", privacy: .private(mask: .hash)) \
            isExecuting=\(coordinator.tabExecution.isAnyExecuting)
            """
        )

        switch result {
        case .skip:
            return
        case .reuseActiveTab:
            coordinator.selectedTabGridModel?.clearSelection()
            coordinator.openTableTab(table, schema: ref.qualifyingSchema)
        case .openNewTab:
            coordinator.openTableTab(table, schema: ref.qualifyingSchema)
        }
    }

    // MARK: - Sidebar Edit Handling

    func updateSidebarEditState() {
        // A selection change, refresh or undo rebuilds the fields, so the typed run ends here, not in another row's step.
        coordinator.endInspectorEditRun()
        trailingPaneState.inspector.editState.detachedStager = coordinator.rowEditingCoordinator
        // A structure definition is edited by the structure inspector, not the row fields.
        switch gridSelectionOwner {
        case .schemaGrid, .none:
            clearSidebarEditState()
            return
        case .dataGrid:
            break
        }

        guard let tab = coordinator.tabManager.selectedTab,
              let model = coordinator.activeGridModel,
              !model.selection.isEmpty
        else {
            clearSidebarEditState()
            return
        }
        // Nothing reads the rows off screen, and the copy grows with rows times columns. A value window holds its own
        // tab and records through the stager, so releasing them strands none of its typing.
        if trailingPaneState.inspector.isOnScreen {
            configureSidebarRows(tab: tab, model: model)
        } else {
            trailingPaneState.inspector.editState.releaseRows()
        }

        guard isSidebarEditable else {
            clearSidebarEditHandlers()
            return
        }

        // Weak: the edit state outlives this view, and a strong capture kept the coordinator until teardown.
        let editState = trailingPaneState.inspector.editState
        let coordinator = self.coordinator
        editState.onFieldChanged = { [weak coordinator, weak editState] columnIndex, newValue, continuity in
            guard let coordinator, let editState else { return }
            coordinator.stageInspectorFieldEdit(
                columnIndex: columnIndex,
                value: newValue,
                rowIDs: editState.rowIDs,
                continuity: continuity
            )
        }
        editState.onFieldExpressionChanged = { [weak coordinator, weak editState] columnIndex, sql, continuity in
            guard let coordinator, let editState else { return }
            coordinator.rowEditingCoordinator.stageInspectorFieldEdit(
                columnIndex: columnIndex,
                value: .text(sql),
                rowIDs: editState.rowIDs,
                continuity: continuity,
                isExpression: true
            )
        }
        editState.onFieldValuesChanged = { [weak coordinator] columnIndex, valuesByRow in
            coordinator?.rowEditingCoordinator.stageInspectorFieldValues(
                columnIndex: columnIndex, valuesByRow: valuesByRow
            )
        }
        editState.onFieldReverted = { [weak coordinator] columnIndex, valuesByRow, absentRowIDs, expressionRowIDs in
            coordinator?.rowEditingCoordinator.revertInspectorFieldEdit(
                columnIndex: columnIndex,
                valuesByRow: valuesByRow,
                absentRowIDs: absentRowIDs,
                expressionRowIDs: expressionRowIDs
            )
        }
        editState.onFieldRemoved = { [weak coordinator] columnIndex, rowIDs in
            coordinator?.stageInspectorFieldRemoval(columnIndex: columnIndex, rowIDs: rowIDs)
        }
    }

    private func configureSidebarRows(tab: QueryTab, model: DataGridModel) {
        let tableRows = model.rows
        let selectedRows = model.selection.affectedRows.compactMap { model.row(at: $0) }
        let allRows = selectedRows.map { Array($0.values) }

        let columnTypes = tableRows.columnTypes.indices.compactMap { tableRows.editingColumnType(at: $0) }

        if !changeManager.hasChanges {
            trailingPaneState.inspector.editState.clearEdits()
        }

        var modifiedColumns = Set<Int>()
        for row in selectedRows {
            modifiedColumns.formUnion(changeManager.getModifiedColumnsForRow(row.id))
        }

        let pkColumns = Set(tab.tableContext.primaryKeyColumns)
        let fkColumns = Set(tableRows.columnForeignKeys.keys)

        let stringRows: [[String?]] = allRows.map { row in
            row.map { cell -> String? in
                switch cell {
                case .null: return nil
                case .text(let s): return s
                case .bytes(let data): return String(data: data, encoding: .isoLatin1) ?? ""
                }
            }
        }
        trailingPaneState.inspector.editState.configure(
            tabId: tab.id,
            rowIDs: selectedRows.map(\.id),
            allRows: stringRows,
            absentCells: selectedRows.map { tableRows.absentColumns(of: $0.id) },
            unloadedCells: selectedRows.map { Set(tableRows.unloadedColumns(of: $0.id).keys) },
            expressionCells: selectedRows.map { changeManager.expressionColumns(forRow: $0.id) },
            columns: tableRows.columns,
            columnTypes: columnTypes,
            externallyModifiedColumns: modifiedColumns,
            primaryKeyColumns: pkColumns,
            foreignKeyColumns: fkColumns,
            serverOwnedColumns: tableRows.generatedColumns.union(changeManager.unwritableColumns(among: tableRows.columns)),
            nonNullableColumns: Set(tableRows.columnNullable.compactMap { $0.value ? nil : $0.key }),
            serverAssignedColumns: Set(tableRows.columns.filter { tableRows.serverAssignsValue(forColumn: $0) }),
            displayFormats: inspectorDisplayFormats(for: tab, columns: tableRows.columns, types: tableRows.columnTypes),
            declaredTypes: tableRows.columnDeclaredTypes,
            binaryColumns: MultiRowEditState.binaryColumns(in: allRows),
            databaseType: connection.type,
            cellWriter: changeManager.cellWriterSupport
        )
    }

    // Only the editor comes from the format; the value stays raw, since a formatted timestamp saved back would corrupt it.
    private func inspectorDisplayFormats(
        for tab: QueryTab,
        columns: [String],
        types: [ColumnType?]
    ) -> [ValueDisplayFormat?] {
        let service = ValueDisplayFormatService.shared
        let scope = tab.tableContext.scope(connectionId: coordinator.connection.id)
        let storageKeys = ValueDisplayFormatColumnKey.storageKeys(for: columns)
        let activeFormats = InspectorValueDisplayFormatResolver.activeFormats(
            from: coordinator.existingGridModel(forTab: tab.id),
            matching: columns
        )
        let storedFormats = activeFormats == nil
            ? storageKeys.map { service.effectiveFormat(columnKey: $0, scope: scope) }
            : []
        return columns.indices.map { index in
            let resolved = InspectorValueDisplayFormatResolver.resolve(
                columnIndex: index,
                activeFormats: activeFormats,
                storedFormat: storedFormats.indices.contains(index) ? storedFormats[index] : .raw,
                columnType: index < types.count ? types[index] : nil,
                databaseType: coordinator.connection.type
            )
            // FieldEditorResolver also reads .raw as skip JSON, PHP and image detection, so no override stays nil.
            return resolved == .raw ? nil : resolved
        }
    }

    private func clearSidebarEditState() {
        trailingPaneState.inspector.editState.fields = []
        clearSidebarEditHandlers()
    }

    private func clearSidebarEditHandlers() {
        trailingPaneState.inspector.editState.onFieldChanged = nil
        trailingPaneState.inspector.editState.onFieldExpressionChanged = nil
        trailingPaneState.inspector.editState.onFieldValuesChanged = nil
        trailingPaneState.inspector.editState.onFieldReverted = nil
        trailingPaneState.inspector.editState.onFieldRemoved = nil
    }
}
