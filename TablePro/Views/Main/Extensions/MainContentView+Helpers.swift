//
//  MainContentView+Helpers.swift
//  TablePro
//
//  Extension containing helper methods and inspector context
//  for MainContentView. Extracted to reduce main view complexity.
//

import SwiftUI
import TableProPluginKit

extension MainContentView {
    // MARK: - Helper Methods

    func loadTableMetadataIfNeeded() async {
        guard let tab = currentTab,
            let tableName = tab.tableContext.tableName,
            !(coordinator.tableMetadata?.tableName == tableName
                && coordinator.hasCurrentTableMetadata(for: tab, tableName: tableName))
        else { return }
        await coordinator.loadTableMetadata(tableName: tableName, for: tab)
    }

    func handleConnectionStatusChange() {
        let sessions = DatabaseManager.shared.activeSessions
        guard let session = sessions[connection.id] else { return }
        if session.isConnected {
            if let trigger = coordinator.pendingLoadTrigger {
                let hasPendingEdits =
                    changeManager.hasChanges
                    || (tabManager.selectedTab?.pendingChanges.hasChanges ?? false)
                if !hasPendingEdits {
                    coordinator.pendingLoadTrigger = nil
                    consumePendingLoad(trigger: trigger)
                }
            } else {
                coordinator.lazyLoadCurrentTabIfNeeded()
            }
        }
        toolbarState.updateConnectionState(from: session.reportedStatus)
        toolbarState.syncFromSession(for: connection)
    }

    private func consumePendingLoad(trigger: TableLoadTrigger) {
        if let tabId = tabManager.selectedTab?.id {
            coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId)
        }
        if tabManager.selectedTab?.tabType == .table {
            coordinator.lazyLoadCurrentTabIfNeeded(trigger: trigger)
        } else {
            coordinator.runQuery(trigger: trigger)
        }
    }

    // MARK: - Inspector Context

    func scheduleInspectorUpdate() {
        inspectorUpdateTask?.cancel()
        inspectorUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            updateSidebarEditState()
            updateInspectorContext()
        }
    }

    func updateInspectorContext() {
        trailingPaneState.inspector.context = RowInspectorContext(
            subject: inspectorSubject,
            hasRow: hasInspectableRow,
            isEditable: isSidebarEditable,
            isRowDeleted: isSelectedRowDeleted,
            tableMetadata: tableMetadataForCurrentTab,
            jsonRow: jsonRowSnapshotForSidebar,
            userDefinedTypeScope: structureTypeScope
        )
        updateAssistantContext()
    }

    /// Built only once the assistant exists. The grid summary is for the chat, and a window whose
    /// assistant was never revealed has nothing to tell.
    func updateAssistantContext() {
        guard trailingPaneState.assistant.isActivated else { return }
        trailingPaneState.assistant.context = AssistantContext(
            currentQuery: coordinator.tabManager.selectedTab?.content.query,
            queryResults: cachedQueryResultsSummary()
        )
    }

    /// Nil on a tab that has no table of its own.
    ///
    /// `coordinator.tableMetadata` is a single latest-wins slot, written by `loadTableMetadata` and
    /// cleared only by `teardown()`. Handing it over unconditionally meant a query tab, a
    /// dashboard, an ER diagram or a Users & Roles tab showed the size, row count and engine of
    /// whichever table had been opened last, labelled as if they described what was on screen, and
    /// closing that table's tab did not clear it.
    private var tableMetadataForCurrentTab: TableMetadata? {
        guard let tableName = currentTab?.tableContext.tableName,
              let metadata = coordinator.tableMetadata,
              metadata.tableName == tableName
        else { return nil }
        return metadata
    }

    /// The scope a structure row's type picker looks types up in: the tab's own database and
    /// schema, never the sidebar's, because a tab bound to another database edits that one.
    private var structureTypeScope: DatabaseScope? {
        guard let tab = currentTab, tab.tabType == .table || tab.tabType == .createTable else { return nil }
        let database = tab.tableContext.databaseName ?? coordinator.browseDatabaseName
        return DatabaseScope(
            connectionId: coordinator.connection.id,
            database: database,
            schema: tab.tableContext.schemaName
        )
    }

    private func cachedQueryResultsSummary() -> String? {
        guard let tab = currentTab else { return nil }
        if let cache = queryResultsSummaryCache,
            cache.tabId == tab.id, cache.version == tab.schemaVersion
        {
            return cache.summary
        }
        let summary = buildQueryResultsSummary()
        queryResultsSummaryCache = (tabId: tab.id, version: tab.schemaVersion, summary: summary)
        return summary
    }

    private func buildQueryResultsSummary() -> String? {
        guard let tab = currentTab else { return nil }
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)
        guard !tableRows.columns.isEmpty, !tableRows.rows.isEmpty else { return nil }

        let columns = tableRows.columns
        let rows = tableRows.rows
        let maxRows = 10
        let displayRows = Array(rows.prefix(maxRows))

        var lines: [String] = []
        lines.append(columns.joined(separator: " | "))

        for row in displayRows {
            let values = columns.indices.map { i -> String in
                guard i < row.values.count else { return "NULL" }
                let raw: String
                switch row.values[i] {
                case .null:
                    raw = "NULL"
                case .text(let s):
                    raw = s
                case .bytes(let data):
                    raw = BlobFormattingService.shared.format(data, for: .copy) ?? ""
                }
                return (raw as NSString).length > 200 ? String(raw.prefix(200)) + "…" : raw
            }
            lines.append(values.joined(separator: " | "))
        }

        if rows.count > maxRows {
            lines.append(String(format: String(localized: "(showing %d of %d rows)"), maxRows, rows.count))
        }

        return lines.joined(separator: "\n")
    }
}
