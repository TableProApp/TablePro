//
//  MainContentView+Helpers.swift
//  TablePro
//
//  Extension containing helper methods and inspector context
//  for MainContentView. Extracted to reduce main view complexity.
//

import SwiftUI

extension MainContentView {
    // MARK: - Helper Methods

    func loadTableMetadataIfNeeded() async {
        guard let tableName = currentTab?.tableContext.tableName,
            coordinator.tableMetadata?.tableName != tableName
        else { return }
        await coordinator.loadTableMetadata(tableName: tableName)
    }

    func handleConnectionStatusChange() {
        let sessions = DatabaseManager.shared.activeSessions
        guard let session = sessions[connection.id] else { return }
        if session.isConnected && coordinator.needsLazyLoad {
            let hasPendingEdits =
                changeManager.hasChanges
                || (tabManager.selectedTab?.pendingChanges.hasChanges ?? false)
            guard !hasPendingEdits else { return }
            coordinator.needsLazyLoad = false
            if let selectedTab = tabManager.selectedTab,
                !selectedTab.tableContext.databaseName.isEmpty,
                selectedTab.tableContext.databaseName != session.activeDatabase
            {
                Task { await coordinator.switchDatabase(to: selectedTab.tableContext.databaseName) }
            } else if let selectedTab = tabManager.selectedTab,
                let tabSchema = selectedTab.tableContext.schemaName,
                !tabSchema.isEmpty,
                tabSchema != session.currentSchema
            {
                // Restore schema on the driver without clearing tabs (unlike switchSchema which resets UI)
                Task {
                    await coordinator.restoreSchemaAndRunQuery(tabSchema)
                }
            } else {
                coordinator.runQuery()
            }
        }
        let mappedState = mapSessionStatus(session.status)
        if mappedState != toolbarState.connectionState {
            toolbarState.connectionState = mappedState
        }
    }

    private func mapSessionStatus(_ status: ConnectionStatus) -> ToolbarConnectionState {
        switch status {
        case .connected: return .connected
        case .connecting: return .executing
        case .disconnected: return .disconnected
        case .error: return .error("")
        }
    }

    // MARK: - Inspector Context

    /// Synchronously updates inspector state. Previously deferred by 100ms to coalesce
    /// multiple onChange calls, but the deferred Task caused a double layout pass.
    func scheduleInspectorUpdate() {
        inspectorUpdateTask?.cancel()
        inspectorUpdateTask = nil
        updateSidebarEditState()
        updateInspectorContext()
    }

    func updateInspectorContext() {
        rightPanelState.inspectorContext = InspectorContext(
            tableName: currentTab?.tableContext.tableName,
            tableMetadata: coordinator.tableMetadata,
            selectedRowData: selectedRowDataForSidebar,
            isEditable: isSidebarEditable,
            isRowDeleted: isSelectedRowDeleted,
            currentQuery: coordinator.tabManager.selectedTab?.content.query,
            queryResults: cachedQueryResultsSummary()
        )
    }

    private func cachedQueryResultsSummary() -> String? {
        guard let tab = currentTab else { return nil }
        if let cache = queryResultsSummaryCache,
            cache.tabId == tab.id, cache.version == tab.resultVersion
        {
            return cache.summary
        }
        let summary = buildQueryResultsSummary()
        queryResultsSummaryCache = (tabId: tab.id, version: tab.resultVersion, summary: summary)
        return summary
    }

    private func buildQueryResultsSummary() -> String? {
        guard let tab = currentTab,
            !tab.resultColumns.isEmpty,
            !tab.resultRows.isEmpty
        else { return nil }

        let columns = tab.resultColumns
        let rows = tab.resultRows
        let maxRows = 10
        let displayRows = Array(rows.prefix(maxRows))

        var lines: [String] = []
        lines.append(columns.joined(separator: " | "))

        for row in displayRows {
            let values = columns.indices.map { i in
                let raw = i < row.count ? (row[i] ?? "NULL") : "NULL"
                return (raw as NSString).length > 200 ? String(raw.prefix(200)) + "..." : raw
            }
            lines.append(values.joined(separator: " | "))
        }

        if rows.count > maxRows {
            lines.append(String(format: String(localized: "(showing %d of %d rows)"), maxRows, rows.count))
        }

        return lines.joined(separator: "\n")
    }
}
