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

        syncSidebarToCurrentTab()
        let t3 = Date()

        guard !coordinator.isTearingDown else { return }
        let aggregated = MainContentCoordinator.aggregatedTabs(for: coordinator.connectionId)
        coordinator.persistence.saveNow(
            windowedTabs: aggregated,
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

        coordinator.persistence.saveOrClearAggregated()
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
            columns: newColumns,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type
        )
    }

    func handleTableSelectionChange(
        from oldTables: Set<TableInfo>, to newTables: Set<TableInfo>
    ) {
        let action = TableSelectionAction.resolve(oldTables: oldTables, newTables: newTables)

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

    /// Keep sidebar selection in sync with the current window's tab.
    /// Only writes when the value actually changes, preventing spurious onChange triggers.
    /// Navigation safety is guaranteed by `SidebarNavigationResult.resolve` returning `.skip`
    /// when the selected table matches the current tab.
    /// Reads from DatabaseManager (authoritative source) instead of the `tables` binding.
    func syncSidebarToCurrentTab() {
        guard coordinator.isKeyWindow else { return }
        let liveTables = DatabaseManager.shared.session(for: connection.id)?.tables ?? []
        let target: Set<TableInfo>
        if let currentTableName = tabManager.selectedTab?.tableContext.tableName,
            let match = liveTables.first(where: { $0.name == currentTableName })
        {
            target = [match]
        } else {
            target = []
        }
        if coordinator.windowSidebarState.selectedTables != target {
            if target.isEmpty && liveTables.isEmpty { return }
            coordinator.windowSidebarState.selectedTables = target
        }
    }

    // MARK: - Sidebar Edit Handling

    func updateSidebarEditState() {
        let selectedIndices = coordinator.selectionState.indices
        guard let tab = coordinator.tabManager.selectedTab,
            !selectedIndices.isEmpty
        else {
            rightPanelState.editState.fields = []
            rightPanelState.editState.onFieldChanged = nil
            return
        }
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)

        var allRows: [[PluginCellValue]] = []
        for index in selectedIndices.sorted() {
            if index < tableRows.rows.count {
                allRows.append(Array(tableRows.rows[index].values))
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

            for rowIndex in capturedEditState.selectedRowIndices {
                guard rowIndex < tableRows.rows.count else { continue }
                let originalRow = Array(tableRows.rows[rowIndex].values)

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
}
