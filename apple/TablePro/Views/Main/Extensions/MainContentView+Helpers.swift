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

    // Keys on whether rows arrived, not when: a read per page would count up to 100,001 SQLite rows or run MongoDB `collStats`.
    struct TableInfoTaskKey: Hashable {
        let tabId: UUID
        let table: TableTabIdentity?
        let hasRows: Bool
        let isInspectorOnScreen: Bool

        init(tab: QueryTab, table: TableTabIdentity?, isInspectorOnScreen: Bool) {
            tabId = tab.id
            self.table = table
            hasRows = tab.execution.lastExecutedAt != nil
            self.isInspectorOnScreen = isInspectorOnScreen
        }
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

    // macOS has no live region for the banner, so it is announced; announcements are app-wide, so only the key window speaks.
    func announceConnectionWarning(_ warning: String?) {
        guard let warning, coordinator.isKeyWindow else { return }
        AccessibilityAnnouncement.post(
            String(format: String(localized: "Connected with a warning. %@"), warning)
        )
    }

    private func consumePendingLoad(trigger: TableLoadTrigger) {
        if let tabId = tabManager.selectedTab?.id {
            coordinator.resolveTableTabSchemaIfNeeded(tabId: tabId)
        }
        if tabManager.selectedTab?.tabType == .table {
            coordinator.lazyLoadCurrentTabIfNeeded(trigger: trigger)
        } else {
            coordinator.runQuery(viewport: .firstRow, trigger: trigger)
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

    func scheduleInspectorContextRefresh() {
        guard trailingPaneState.inspector.viewMode == .json else { return }
        inspectorContextRefreshTask?.cancel()
        inspectorContextRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
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

    // The grid summary is for the chat, so a window whose assistant was never revealed builds nothing.
    func updateAssistantContext() {
        guard trailingPaneState.assistant.isActivated else { return }
        let snapshot = coordinator.assistantEditorSnapshot
        trailingPaneState.assistant.context = AssistantContext(
            currentQuery: snapshot.currentQuery,
            queryResults: cachedQueryResultsSummary(),
            editorTarget: snapshot.target
        )
    }

    // Per-tab cache: a single latest-wins slot showed whichever table loaded last, even on a query tab or another database.
    var tableMetadataForCurrentTab: TableMetadata? {
        currentTab.flatMap { coordinator.currentTableMetadata(for: $0) }
    }

    // The tab's own database and schema, never the sidebar's: a tab bound to another database edits that one.
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
                if let byteCount = row.unloadedByteCount(i) {
                    return DataGridCellContent.unloadedSpokenText(byteCount: byteCount)
                }
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

// The inspector shows one row's values, so it loads that row's unloaded values while it is on screen.
internal struct InspectorValueLoadModifier: ViewModifier {
    @ObservedObject var inspector: RowInspectorState
    let model: DataGridModel?
    let tabId: UUID?
    let contentVersion: Int
    let load: (UUID, RowID) async -> Void

    func body(content: Content) -> some View {
        content.background {
            if let model, let tabId {
                InspectorValueLoader(
                    model: model,
                    isOnScreen: inspector.isOnScreen,
                    tabId: tabId,
                    contentVersion: contentVersion,
                    load: load
                )
            }
        }
    }
}

// Observes the grid model here, so a selection change redraws this and not the window's content view.
private struct InspectorValueLoader: View {
    @ObservedObject var model: DataGridModel
    let isOnScreen: Bool
    let tabId: UUID
    let contentVersion: Int
    let load: (UUID, RowID) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key) {
                guard let key else { return }
                await load(key.tabId, key.rowID)
            }
    }

    private var key: Key? {
        guard isOnScreen, model.selection.affectedRows.count == 1,
              let rowID = model.selectedRowIDs.first else { return nil }
        return Key(tabId: tabId, rowID: rowID, contentVersion: contentVersion)
    }

    struct Key: Hashable {
        let tabId: UUID
        let rowID: RowID
        let contentVersion: Int
    }
}

// `MainContentView` does not observe the inspector, so a key built in its body never saw `isOnScreen` move.
internal struct TableInfoLoadModifier: ViewModifier {
    @ObservedObject var inspector: RowInspectorState
    let tab: QueryTab?
    let table: TableTabIdentity?
    let load: (QueryTab) async -> Void

    func body(content: Content) -> some View {
        content.task(id: key) {
            guard let tab else { return }
            await load(tab)
        }
    }

    private var key: MainContentView.TableInfoTaskKey? {
        tab.map { MainContentView.TableInfoTaskKey(tab: $0, table: table, isInspectorOnScreen: inspector.isOnScreen) }
    }
}
