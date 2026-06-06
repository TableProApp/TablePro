//
//  MainContentCoordinator+WindowLifecycle.swift
//  TablePro
//
//  Window-lifecycle handlers invoked by TabWindowController's NSWindowDelegate
//  methods. windowDidBecomeKey is intentionally lightweight (focus state +
//  sidebar sync only) per Apple's documentation; visibility-scoped lazy-load
//  lives in MainEditorContentView's `.task(id:)` modifier.
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

extension MainContentCoordinator {
    // MARK: - Window Delegate Dispatch

    /// Called from `TabWindowController.windowDidBecomeKey(_:)`.
    /// Updates focus state, refreshes file-based schema if stale, and syncs the
    /// sidebar selection to the active tab. No query work runs here — lazy-load
    /// is owned by `MainEditorContentView`'s `.task(id:)` modifier.
    func handleWindowDidBecomeKey() {
        let t0 = Date()
        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey connId=\(self.connectionId, privacy: .public) selectedTabId=\(self.tabManager.selectedTabId?.uuidString ?? "nil", privacy: .public)"
        )
        isKeyWindow = true
        evictionTask?.cancel()
        evictionTask = nil

        syncSidebarToSelectedTab()
        announceActiveTabToVoiceOver()

        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey done connId=\(self.connectionId, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

    /// Called from `TabWindowController.windowDidResignKey(_:)`.
    /// Schedules a 5s-delayed eviction of row data in inactive tabs; a fresh
    /// `windowDidBecomeKey` cancels the eviction before it fires.
    func handleWindowDidResignKey() {
        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidResignKey connId=\(self.connectionId, privacy: .public)"
        )
        isKeyWindow = false

        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            Self.lifecycleLogger.debug(
                "[switch] coordinator evictInactiveRowData firing (5s after resignKey) connId=\(self.connectionId, privacy: .public)"
            )
            self.evictInactiveRowData()
        }
    }

    /// Called from `TabWindowController.windowWillClose(_:)`.
    /// Synchronous teardown — no grace period, no delayed Task. Writes tab
    /// state to disk, releases SwiftUI-scoped right-panel state, then
    /// disconnects the session if this was the last window for the connection.
    func handleWindowWillClose() {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[close] coordinator.handleWindowWillClose connId=\(self.connectionId, privacy: .public) tabs=\(self.tabManager.tabs.count)"
        )

        if !MainContentCoordinator.isAppTerminating {
            persistence.saveOrClearAggregatedSync()
        }

        evictionTask?.cancel()
        evictionTask = nil

        rightPanelState?.teardown()

        teardown()

        Self.lifecycleLogger.info(
            "[close] coordinator.handleWindowWillClose done connId=\(self.connectionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

    /// Announce the active tab title to VoiceOver when the window becomes key,
    /// so assistive-technology users get the same context the window title gives.
    private func announceActiveTabToVoiceOver() {
        guard let title = tabManager.selectedTab?.title, !title.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: title,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: - Sidebar Sync

    /// Update the window-scoped sidebar selection so the active table tab
    /// is highlighted. Reads tables fresh from the DatabaseManager because the
    /// schema load is async and may complete after focus changes.
    func syncSidebarToSelectedTab() {
        let liveTables = DatabaseManager.shared
            .session(for: connectionId)?.tables ?? []
        let target: Set<TableInfo>
        if let currentTableName = tabManager.selectedTab?.tableContext.tableName,
           let match = liveTables.first(where: { $0.name == currentTableName }) {
            target = [match]
        } else {
            target = []
        }
        if windowSidebarState.selectedTables != target {
            if target.isEmpty && liveTables.isEmpty { return }
            windowSidebarState.selectedTables = target
        }
    }

    // MARK: - Lazy Load

    func lazyLoadCurrentTabIfNeeded() {
        guard let tab = tabManager.selectedTab else { return }
        guard canAutoLoadTableTab(tab) else { return }
        guard tableLoadTasks[tab.id] == nil else { return }

        clearAbandonedExecutingFlagIfNeeded(for: tab)

        guard let session = DatabaseManager.shared.session(for: connectionId),
              session.isConnected else {
            needsLazyLoad = true
            return
        }

        let tabId = tab.id
        Self.lifecycleLogger.debug(
            "[switch] coordinator.lazyLoadCurrentTabIfNeeded executing tabId=\(tabId, privacy: .public)"
        )
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.tableLoadTasks[tabId]?.token == token {
                    self.tableLoadTasks[tabId] = nil
                }
            }
            await self.openTableTabQuery(tabId: tabId)
            if let queryTask = self.currentQueryTask {
                await queryTask.value
            }
        }
        tableLoadTasks[tabId] = (token, task)
    }

    func cancelTableLoad(for tabId: UUID) {
        tableLoadTasks[tabId]?.task.cancel()
        tableLoadTasks[tabId] = nil
    }

    private func canAutoLoadTableTab(_ tab: QueryTab) -> Bool {
        guard tab.tabType == .table else { return false }
        guard tab.execution.errorMessage == nil else { return false }
        guard !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let rows = tabSessionRegistry.tableRows(for: tab.id)
        let isEvicted = tabSessionRegistry.isEvicted(tab.id)
        let hasFreshRows = !rows.rows.isEmpty && !isEvicted
        let hasExecuted = tab.execution.lastExecutedAt != nil && !isEvicted
        guard !hasFreshRows, !hasExecuted else { return false }

        let hasPendingEdits = changeManager.hasChanges || tab.pendingChanges.hasChanges
        return !hasPendingEdits
    }

    private func clearAbandonedExecutingFlagIfNeeded(for tab: QueryTab) {
        guard tab.execution.isExecuting, currentQueryTask == nil else { return }
        tabManager.mutate(tabId: tab.id) { $0.execution.isExecuting = false }
    }
}
