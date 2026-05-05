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

        let isConnected =
            DatabaseManager.shared.activeSessions[connectionId]?.isConnected ?? false
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased && isConnected {
            Task { await self.refreshTablesIfStale() }
        }

        syncSidebarToSelectedTab()

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

    // MARK: - Sidebar Sync

    /// Update the connection-scoped sidebar selection so the active table tab
    /// is highlighted. Reads tables fresh from the DatabaseManager because the
    /// schema load is async and may complete after focus changes.
    func syncSidebarToSelectedTab() {
        let sidebarState = SharedSidebarState.forConnection(connectionId)
        let liveTables = DatabaseManager.shared
            .session(for: connectionId)?.tables ?? []
        let target: Set<TableInfo>
        if let currentTableName = tabManager.selectedTab?.tableContext.tableName,
           let match = liveTables.first(where: { $0.name == currentTableName }) {
            target = [match]
        } else {
            target = []
        }
        if sidebarState.selectedTables != target {
            if target.isEmpty && liveTables.isEmpty { return }
            sidebarState.selectedTables = target
        }
    }

    // MARK: - Lazy Load

    /// Execute the current tab's query if it is a table tab whose row data is
    /// missing or evicted. Apple-pattern guards in cheap-content-first order:
    /// trivial content checks reject before the expensive connection probe.
    /// Idempotent — repeated calls with the same state are no-ops.
    func lazyLoadCurrentTabIfNeeded() {
        guard let tab = tabManager.selectedTab else { return }
        guard tab.tabType == .table else { return }
        guard tab.execution.errorMessage == nil else { return }
        guard !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let rows = tabSessionRegistry.tableRows(for: tab.id)
        let isEvicted = tabSessionRegistry.isEvicted(tab.id)
        let hasFreshRows = !rows.rows.isEmpty && !isEvicted
        let hasExecuted = tab.execution.lastExecutedAt != nil && !isEvicted
        guard !hasFreshRows, !hasExecuted else { return }

        let hasPendingEdits =
            changeManager.hasChanges
            || tab.pendingChanges.hasChanges
        guard !hasPendingEdits else { return }

        // A previous load that was cancelled mid-flight (e.g. user rapidly
        // switched away) leaves `isExecuting = true` with no rows and no
        // `lastExecutedAt`. Clear the stale flag inline so the executor's
        // own `!tab.execution.isExecuting` guard inside
        // `executeTableTabQueryDirectly` doesn't suppress this re-fire.
        if tab.execution.isExecuting && rows.rows.isEmpty && tab.execution.lastExecutedAt == nil,
           let idx = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) {
            tabManager.tabs[idx].execution.isExecuting = false
        } else if tab.execution.isExecuting {
            return
        }

        guard let session = DatabaseManager.shared.session(for: connectionId),
              session.isConnected else {
            needsLazyLoad = true
            return
        }

        Self.lifecycleLogger.debug(
            "[switch] coordinator.lazyLoadCurrentTabIfNeeded executing tabId=\(tab.id, privacy: .public) evicted=\(isEvicted)"
        )
        executeTableTabQueryDirectly()
    }
}
