//
//  MainContentView+EventHandlers.swift
//  TablePro
//
//  Extension containing event handler methods for MainContentView.
//  Extracted to reduce main view complexity.
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

        /// A tab selection change in a background window is usually a side effect rather than
        /// navigation, a close refocusing its neighbour above all, and that window re-marks its own
        /// object tree the moment it becomes key.
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
        // Skip during tab switch — handleTabChange already configures the change manager
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

        changeManager.configureForTable(
            tableName: tab.tableContext.tableName ?? "",
            schemaName: tab.tableContext.schemaName,
            columns: newColumns,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type
        )
    }

    func handleTableSelectionChange(
        from oldTables: Set<TableInfo>, to newTables: Set<TableInfo>
    ) {
        let action = TableSelectionAction.resolve(
            oldTables: oldTables,
            newTables: newTables,
            selectedRowCount: coordinator.windowSidebarState.selectedRowCount
        )

        guard case .navigate(let table) = action else {
            return
        }

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
            [tableload] sidebarSelection table=\(table.name, privacy: .public) \
            decision=\(String(describing: result), privacy: .public) \
            currentTab=\(tabManager.selectedTab?.tableContext.tableName ?? "none", privacy: .public) \
            isExecuting=\(coordinator.tabExecution.isAnyExecuting)
            """
        )

        switch result {
        case .skip:
            return
        case .reuseActiveTab:
            coordinator.selectionState.indices = []
            coordinator.openTableTab(table)
        case .openNewTab:
            coordinator.openTableTab(table)
        }
    }

    // MARK: - Sidebar Edit Handling

    func updateSidebarEditState() {
        switch gridSelectionOwner {
        case .schemaGrid:
            updateSchemaSidebarEditState()
            return
        case .none:
            clearSidebarEditState()
            return
        case .dataGrid:
            break
        }

        let selectedIndices = coordinator.selectionState.indices
        guard let tab = coordinator.tabManager.selectedTab,
            !selectedIndices.isEmpty
        else {
            clearSidebarEditState()
            return
        }
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)

        let displayIDs = coordinator.activeGridDisplayIDs
        var allRows: [[PluginCellValue]] = []
        for displayIndex in selectedIndices.sorted() {
            if let row = DisplayRowMapping.row(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows) {
                allRows.append(Array(row.values))
            }
        }

        var columnTypes = tableRows.columnTypes
        for (i, col) in tableRows.columns.enumerated() where i < columnTypes.count {
            if let values = tableRows.columnEnumValues[col], !values.isEmpty {
                let ct = columnTypes[i]
                if ct.isEnumType {
                    columnTypes[i] = .enumType(rawType: ct.rawType, values: values)
                } else if ct.isSetType {
                    columnTypes[i] = .set(rawType: ct.rawType, values: values)
                }
            }
        }

        if !changeManager.hasChanges {
            rightPanelState.editState.clearEdits()
        }

        var modifiedColumns = Set<Int>()
        for rowIndex in selectedIndices {
            modifiedColumns.formUnion(changeManager.getModifiedColumnsForRow(rowIndex))
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
        rightPanelState.editState.configure(
            selectedRowIndices: selectedIndices,
            allRows: stringRows,
            columns: tableRows.columns,
            columnTypes: columnTypes,
            externallyModifiedColumns: modifiedColumns,
            primaryKeyColumns: pkColumns,
            foreignKeyColumns: fkColumns
        )

        guard isSidebarEditable else {
            rightPanelState.editState.onFieldChanged = nil
            return
        }

        let capturedCoordinator = coordinator
        let capturedEditState = rightPanelState.editState
        rightPanelState.editState.onFieldChanged = { columnIndex, newValue in
            guard let tab = capturedCoordinator.tabManager.selectedTab else { return }
            let tableRows = capturedCoordinator.tabSessionRegistry.tableRows(for: tab.id)
            let columnName =
                columnIndex < tableRows.columns.count ? tableRows.columns[columnIndex] : ""

            let displayIDs = capturedCoordinator.activeGridDisplayIDs
            for rowIndex in capturedEditState.selectedRowIndices {
                guard let resolvedRow = DisplayRowMapping.row(
                    forDisplay: rowIndex,
                    displayIDs: displayIDs,
                    in: tableRows
                ) else { continue }
                let originalRow = Array(resolvedRow.values)

                let oldValue: PluginCellValue
                if columnIndex < capturedEditState.fields.count {
                    oldValue = PluginCellValue.fromOptional(capturedEditState.fields[columnIndex].originalValue)
                } else if columnIndex < originalRow.count {
                    oldValue = originalRow[columnIndex]
                } else {
                    oldValue = .null
                }

                capturedCoordinator.changeManager.recordCellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: oldValue,
                    newValue: newValue,
                    originalRow: originalRow
                )
            }
        }
    }

    private func clearSidebarEditState() {
        rightPanelState.editState.fields = []
        rightPanelState.editState.onFieldChanged = nil
    }

    /// Populate the inspector from the grid that owns a schema selection, and send every
    /// edit back to it so a change lands in its change manager exactly as an inline
    /// grid edit does, with one undo step and one pending change.
    private func updateSchemaSidebarEditState() {
        guard let displayRow = coordinator.selectionState.indices.min(),
            let row = selectedInspectorRow
        else {
            clearSidebarEditState()
            return
        }

        rightPanelState.editState.configure(schemaFields: row.fields, displayRow: displayRow)

        guard row.isEditable else {
            rightPanelState.editState.onFieldChanged = nil
            return
        }

        let capturedCoordinator = coordinator
        rightPanelState.editState.onFieldChanged = { fieldIndex, newValue in
            capturedCoordinator.inspectorRowSource?.commitInspectorField(
                displayRow: displayRow,
                fieldIndex: fieldIndex,
                value: newValue.asText
            )
            capturedCoordinator.inspectorRowSourceRevision += 1
        }
    }
}
