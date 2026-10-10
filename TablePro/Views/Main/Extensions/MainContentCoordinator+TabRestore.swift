//
//  MainContentCoordinator+TabRestore.swift
//  TablePro
//

import AppKit
import Foundation
import os

internal enum RestoreLoadTiming {
    case immediate
    case deferred
}

extension MainContentCoordinator {
    /// The table load runs only for a tab that came from disk. A present tab was opened by whoever
    /// put it there, which already loaded it or chose not to.
    ///
    /// The container switch is awaited, because a tab moved in after the restore binds to the
    /// database the connection is browsing, and that has to be the restored one.
    private func restoreConnectionContext(
        for selected: QueryTab,
        loadsSelectedTab: Bool,
        activeDatabase: String?,
        activeSchema: String?,
        loadTiming: RestoreLoadTiming
    ) async {
        let isTableTab = loadsSelectedTab
            && selected.tabType == .table
            && !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard loadTiming == .immediate else {
            if isTableTab {
                deferredRestoreLoadTabId = selected.id
            }
            return
        }

        guard let session = DatabaseManager.shared.activeSessions[connection.id], session.isConnected else {
            if isTableTab { pendingLoadTrigger = .restore }
            return
        }

        await switchContainers(database: activeDatabase, schema: activeSchema)
        if isTableTab {
            lazyLoadCurrentTabIfNeeded(trigger: .restore)
        }
    }

    /// The present tabs are read here, after the disk read, because more can arrive while it is in
    /// flight. `RestoredTabMerge` says why this merges.
    private func applyRestoredGroup(
        _ tabs: [QueryTab],
        selectedTabId: UUID?,
        activeDatabase: String? = nil,
        activeSchema: String? = nil,
        loadTiming: RestoreLoadTiming = .immediate
    ) async {
        let heldElsewhere = Set(
            WindowManager.shared.coordinators(for: connection.id)
                .filter { $0 !== self }
                .flatMap { $0.tabManager.tabs.map(\.id) }
        )
        let merge = RestoredTabMerge.merge(
            restored: tabs,
            restoredSelection: selectedTabId,
            present: tabManager.tabs,
            presentSelection: tabManager.selectedTabId,
            heldElsewhere: heldElsewhere
        )
        guard !merge.restoredTabIds.isEmpty else { return }
        tabManager.tabs = merge.tabs
        tabManager.selectedTabId = merge.selectedTabId
        for renamedId in merge.renamedTabIds {
            tabManager.markTabRenamed(renamedId)
        }

        guard let selected = tabManager.selectedTab else { return }
        let selectedIsRestored = merge.restoredTabIds.contains(selected.id)

        if selectedIsRestored,
            selected.tabType == .table,
            !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            restoreLastHiddenColumnsForTable()
        }

        /// Every restored table tab, not just the selected one. A tab whose filters were never loaded
        /// holds an empty set, and the next tab switch saves that over the filters the reader left on
        /// the table, because an empty set is what the storage reads as a delete. The hidden columns
        /// above go first, so the query this rebuilds for the selected tab selects the right ones.
        for index in tabManager.tabs.indices
            where tabManager.tabs[index].tabType == .table && merge.restoredTabIds.contains(tabManager.tabs[index].id) {
            restoreFilters(forTabAt: index)
        }

        await restoreConnectionContext(
            for: selected,
            loadsSelectedTab: selectedIsRestored,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            loadTiming: loadTiming
        )
    }

    internal func restoreSavedTabs() async {
        /// The split view controller owns the window and is wired up before the content view is built,
        /// unlike the content view's own window, which arrives from `configureWindow`.
        guard let window = splitViewController?.view.window else {
            Self.lifecycleLogger.error(
                "[open] restoreSavedTabs has no window windowId=\(self.windowId?.uuidString ?? "nil", privacy: .public)"
            )
            return
        }
        let restoreStart = Date()
        let result = await persistence.restoreFromDisk()
        Self.lifecycleLogger.info(
            "[open] restoreFromDisk done windowId=\(self.windowId?.uuidString ?? "nil", privacy: .public) tabsRestored=\(result.tabs.count) source=\(String(describing: result.source), privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(restoreStart) * 1_000))"
        )
        guard !result.tabs.isEmpty, !isTearingDown else { return }

        var restoredTabs = result.tabs
        for i in restoredTabs.indices where restoredTabs[i].tabType == .table {
            if let tableName = restoredTabs[i].tableContext.tableName {
                do {
                    restoredTabs[i].content.query = try QueryTab.buildBaseTableQuery(
                        tableName: tableName,
                        databaseType: connection.type,
                        schemaName: restoredTabs[i].tableContext.schemaName
                    )
                } catch {
                    Self.lifecycleLogger.error(
                        "[open] buildBaseTableQuery failed for restored tab table=\(tableName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
                    )
                }
            }
        }

        /// One window hosts every connection, so a connection's saved tabs all belong to the one
        /// tab list. The old shape split them across windows by a saved group index, which now
        /// has nowhere to go: a group handed back to `openTab` restores nothing and the next
        /// autosave erases it.
        await applyRestoredGroup(
            restoredTabs,
            selectedTabId: result.selectedTabId ?? restoredTabs.first?.id,
            activeDatabase: result.lastActiveDatabase,
            activeSchema: result.lastActiveSchema,
            loadTiming: window.isKeyWindow ? .immediate : .deferred
        )
    }
}
