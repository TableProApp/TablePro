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
        // Skip during tab switch: handleTabChange already configures the change manager
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
            currentTab=\(tabManager.selectedTab?.tableContext.tableName ?? "none", privacy: .public) \
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
            rowIDs: selectedRows.map(\.id),
            allRows: stringRows,
            absentCells: selectedRows.map(\.absentColumns),
            unloadedCells: selectedRows.map { Set($0.unloadedColumns.keys) },
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

        guard isSidebarEditable else {
            clearSidebarEditHandlers()
            return
        }

        let capturedCoordinator = coordinator
        let capturedEditState = trailingPaneState.inspector.editState
        trailingPaneState.inspector.editState.onFieldChanged = { columnIndex, newValue, continuity in
            capturedCoordinator.stageInspectorFieldEdit(
                columnIndex: columnIndex,
                value: newValue,
                rowIDs: capturedEditState.rowIDs,
                continuity: continuity
            )
        }
        trailingPaneState.inspector.editState.onFieldExpressionChanged = { columnIndex, sql, continuity in
            capturedCoordinator.rowEditingCoordinator.stageInspectorFieldEdit(
                columnIndex: columnIndex,
                value: .text(sql),
                rowIDs: capturedEditState.rowIDs,
                continuity: continuity,
                isExpression: true
            )
        }
        trailingPaneState.inspector.editState.onFieldValuesChanged = { columnIndex, valuesByRow in
            capturedCoordinator.rowEditingCoordinator.stageInspectorFieldValues(
                columnIndex: columnIndex, valuesByRow: valuesByRow
            )
        }
        trailingPaneState.inspector.editState.onFieldReverted = { columnIndex, valuesByRow, absentRowIDs, expressionRowIDs in
            capturedCoordinator.rowEditingCoordinator.revertInspectorFieldEdit(
                columnIndex: columnIndex,
                valuesByRow: valuesByRow,
                absentRowIDs: absentRowIDs,
                expressionRowIDs: expressionRowIDs
            )
        }
        trailingPaneState.inspector.editState.onFieldRemoved = { columnIndex, rowIDs in
            capturedCoordinator.stageInspectorFieldRemoval(columnIndex: columnIndex, rowIDs: rowIDs)
        }
        trailingPaneState.inspector.editState.onDetachedFieldChanged = { columnIndex, newValue, rowIDs, isExpression in
            // A value window commits per keystroke like its field, so its typing folds into one undo step the same way.
            capturedCoordinator.rowEditingCoordinator.stageInspectorFieldEdit(
                columnIndex: columnIndex,
                value: newValue,
                rowIDs: rowIDs,
                continuity: .typing,
                isExpression: isExpression
            )
        }
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
        trailingPaneState.inspector.editState.onDetachedFieldChanged = nil
    }
}
