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

    /// What the Table Info load waits for, so it runs again once each of them moves.
    ///
    /// The load waits for the tab's rows. Without `hasRows`, a table tab that had just opened ran the
    /// load before they arrived and never again, so the panel showed no numbers until the inspector
    /// left the screen and came back. Whether rows arrived, not when: a page, a sort or a filter
    /// runs the query again without changing the size or the row count, and a read per page would
    /// count up to 100,001 rows on SQLite and run `collStats` on MongoDB each time. The whole
    /// identity, not the name, because `tenant_a.orders` and `tenant_b.orders` are two tables.
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

    /// The banner appears without the user doing anything and macOS has no live region for it, so VoiceOver
    /// hears it only through an announcement. Every window on the session shows the banner, and announcements
    /// are app-wide, so only the key window speaks.
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

    /// Built only once the assistant exists. The grid summary is for the chat, and a window whose
    /// assistant was never revealed has nothing to tell.
    func updateAssistantContext() {
        guard trailingPaneState.assistant.isActivated else { return }
        let snapshot = coordinator.assistantEditorSnapshot
        trailingPaneState.assistant.context = AssistantContext(
            currentQuery: snapshot.currentQuery,
            queryResults: cachedQueryResultsSummary(),
            editorTarget: snapshot.target
        )
    }

    /// Nil on a tab that has no table of its own. Read from the entry cached for this tab: a single
    /// latest-wins slot showed a query tab, a dashboard, or a table of the same name in another
    /// database the numbers of whichever table had loaded last.
    var tableMetadataForCurrentTab: TableMetadata? {
        currentTab.flatMap { coordinator.currentTableMetadata(for: $0) }
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
    @ObservedObject var selection: GridSelectionState
    let tabId: UUID?
    let contentVersion: Int
    let load: (UUID, Int) async -> Void

    func body(content: Content) -> some View {
        content.task(id: key) {
            guard let key else { return }
            await load(key.tabId, key.displayRow)
        }
    }

    private var key: Key? {
        guard inspector.isOnScreen, let tabId, selection.indices.count == 1,
              let displayRow = selection.indices.first else { return nil }
        return Key(tabId: tabId, displayRow: displayRow, contentVersion: contentVersion)
    }

    struct Key: Hashable {
        let tabId: UUID
        let displayRow: Int
        let contentVersion: Int
    }
}

/// Runs the Table Info load where the inspector's on-screen state is observed.
///
/// `MainContentView` does not observe the inspector, whose context changes on every selection, so a
/// key built in its body never saw `isOnScreen` move. Observed here, only this modifier redraws.
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
