//
//  MainContentView+EventHandlers.swift
//  TablePro
//
//  Extension containing event handler methods for MainContentView.
//  Extracted to reduce main view complexity.
//

import os
import SwiftUI

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
        coordinator.persistence.saveNow(
            tabs: tabManager.tabs,
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

        // Prune hidden columns that no longer exist in results
        if let newColumns = newColumns {
            coordinator.pruneHiddenColumns(currentColumns: newColumns)
        }

        guard let newColumns = newColumns, !newColumns.isEmpty,
            let tab = tabManager.selectedTab,
            !changeManager.hasChanges
        else { return }

        // Reconfigure if columns changed OR table name changed (switching tables)
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

        guard case .navigate(let tableName, let isView) = action else {
            return
        }

        // Only navigate when this is the focused window.
        // Prevents feedback loops when shared sidebar state syncs across native tabs.
        guard coordinator.isKeyWindow else {
            return
        }

        let isPreviewMode = AppSettingsManager.shared.tabs.enablePreviewTabs
        let hasPreview = WindowLifecycleMonitor.shared.previewWindow(for: connection.id) != nil

        let result = SidebarNavigationResult.resolve(
            clickedTableName: tableName,
            currentTabTableName: tabManager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !tabManager.tabs.isEmpty,
            isPreviewTabMode: isPreviewMode,
            hasPreviewTab: hasPreview
        )

        switch result {
        case .skip:
            return
        case .openInPlace:
            coordinator.selectionState.indices = []
            coordinator.openTableTab(tableName, isView: isView)
        case .revertAndOpenNewWindow:
            coordinator.openTableTab(tableName, isView: isView)
        case .replacePreviewTab, .openNewPreviewTab:
            coordinator.openTableTab(tableName, isView: isView)
        }
    }

    /// Keep sidebar selection in sync with the current window's tab.
    /// Only writes when the value actually changes, preventing spurious onChange triggers.
    /// Navigation safety is guaranteed by `SidebarNavigationResult.resolve` returning `.skip`
    /// when the selected table matches the current tab.
    /// Reads from DatabaseManager (authoritative source) instead of the `tables` binding,
    /// and skips background windows to avoid overwriting shared sidebar state.
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
        if sidebarState.selectedTables != target {
            if target.isEmpty && liveTables.isEmpty { return }
            sidebarState.selectedTables = target
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

        var allRows: [[String?]] = []
        for index in selectedIndices.sorted() {
            if index < tableRows.rows.count {
                allRows.append(tableRows.rows[index].values)
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

        let excludedNames: Set<String>
        if let tableName = tab.tableContext.tableName {
            excludedNames = Set(coordinator.columnExclusions(for: tableName).map(\.columnName))
        } else {
            excludedNames = []
        }

        let pkColumns = Set(tab.tableContext.primaryKeyColumns)
        let fkColumns = Set(tableRows.columnForeignKeys.keys)

        rightPanelState.editState.configure(
            selectedRowIndices: selectedIndices,
            allRows: allRows,
            columns: tableRows.columns,
            columnTypes: columnTypes,
            externallyModifiedColumns: modifiedColumns,
            excludedColumnNames: excludedNames,
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
                let originalRow = tableRows.rows[rowIndex].values

                let oldValue: String?
                if columnIndex < capturedEditState.fields.count,
                    !capturedEditState.fields[columnIndex].isTruncated
                {
                    oldValue = capturedEditState.fields[columnIndex].originalValue
                } else {
                    oldValue = columnIndex < originalRow.count ? originalRow[columnIndex] : nil
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

    func lazyLoadExcludedColumnsIfNeeded() {
        guard let tab = coordinator.tabManager.selectedTab else { return }
        let selectedIndices = coordinator.selectionState.indices

        let excludedNames: Set<String>
        if let tableName = tab.tableContext.tableName {
            excludedNames = Set(coordinator.columnExclusions(for: tableName).map(\.columnName))
        } else {
            excludedNames = []
        }

        let capturedCoordinator = coordinator
        let capturedEditState = rightPanelState.editState

        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)
        if !excludedNames.isEmpty,
            selectedIndices.count == 1,
            let tableName = tab.tableContext.tableName,
            let pkColumn = tab.tableContext.primaryKeyColumn,
            let rowIndex = selectedIndices.first,
            rowIndex < tableRows.rows.count
        {
            let row = tableRows.rows[rowIndex].values
            if let pkColIndex = tableRows.columns.firstIndex(of: pkColumn),
                pkColIndex < row.count,
                let pkValue = row[pkColIndex]
            {
                let excludedList = Array(excludedNames)

                lazyLoadTask?.cancel()
                lazyLoadTask = Task { @MainActor in
                    let expectedRowIndex = rowIndex
                    do {
                        let fullValues =
                            try await capturedCoordinator.fetchFullValuesForExcludedColumns(
                                tableName: tableName,
                                primaryKeyColumn: pkColumn,
                                primaryKeyValue: pkValue,
                                excludedColumnNames: excludedList
                            )
                        guard !Task.isCancelled,
                            capturedEditState.selectedRowIndices.count == 1,
                            capturedEditState.selectedRowIndices.first == expectedRowIndex
                        else { return }
                        capturedEditState.applyFullValues(fullValues)
                    } catch {
                        guard !Task.isCancelled,
                            capturedEditState.selectedRowIndices.count == 1,
                            capturedEditState.selectedRowIndices.first == expectedRowIndex
                        else { return }
                        for i in 0..<capturedEditState.fields.count
                        where capturedEditState.fields[i].isLoadingFullValue {
                            capturedEditState.fields[i].isLoadingFullValue = false
                        }
                    }
                }
            }
        }
    }
}
