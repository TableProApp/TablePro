//
//  MainContentCoordinator+WindowLifecycle.swift
//  TablePro
//
//  Window-lifecycle handlers invoked by TabWindowController's NSWindowDelegate
//  methods. Replaces the global `NotificationCenter.default.publisher(for:
//  NSWindow.didBecomeKeyNotification)` observers previously in MainContentView
//  (one fired per ContentView instance, producing 10-14 handler invocations
//  per focus change). Each window's TabWindowController now dispatches to the
//  matching coordinator exactly once.
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

extension MainContentCoordinator {
    // MARK: - Window Delegate Dispatch

    /// Called from `TabWindowController.windowDidBecomeKey(_:)`.
    /// Runs lazy-load + file-based schema refresh, then invokes the view-layer
    /// sidebar-sync callback set by MainContentView.
    func handleWindowDidBecomeKey() {
        let t0 = Date()
        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey connId=\(self.connectionId, privacy: .public) selectedTabId=\(self.tabManager.selectedTabId?.uuidString ?? "nil", privacy: .public)"
        )
        isKeyWindow = true
        evictionTask?.cancel()
        evictionTask = nil

        // Lazy-load: execute query for restored tabs that skipped auto-execute,
        // or re-query tabs whose row data was evicted while inactive.
        // Skip if the user has unsaved changes (in-memory or tab-level).
        let hasPendingEdits =
            changeManager.hasChanges
            || (tabManager.selectedTab?.pendingChanges.hasChanges ?? false)
        let isConnected =
            DatabaseManager.shared.activeSessions[connectionId]?.isConnected ?? false
        let needsLazyLoad =
            tabManager.selectedTab.map { tab in
                tab.tabType == .table
                    && (tab.resultRows.isEmpty || tab.rowBuffer.isEvicted)
                    && (tab.lastExecutedAt == nil || tab.rowBuffer.isEvicted)
                    && tab.errorMessage == nil
                    && !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
        // Skip lazy-load if this is a menu-interaction bounce (resign+become within 200ms).
        let isMenuBounce = Date().timeIntervalSince(lastResignKeyDate) < 0.2
        if needsLazyLoad && !hasPendingEdits && isConnected && !isMenuBounce {
            Self.lifecycleLogger.debug(
                "[switch] coordinator triggering lazy runQuery connId=\(self.connectionId, privacy: .public)"
            )
            runQuery()
        }
        let t1 = Date()

        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased && isConnected {
            Task { await self.refreshTablesIfStale() }
        }
        let t2 = Date()

        onWindowBecameKey?()
        let t3 = Date()

        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey done connId=\(self.connectionId, privacy: .public) lazyQuery=\(Int(t1.timeIntervalSince(t0) * 1_000))ms schemaRefresh=\(Int(t2.timeIntervalSince(t1) * 1_000))ms sidebarSync=\(Int(t3.timeIntervalSince(t2) * 1_000))ms totalMs=\(Int(Date().timeIntervalSince(t0) * 1_000)) lazyLoad=\(needsLazyLoad && !hasPendingEdits && isConnected && !isMenuBounce) menuBounce=\(isMenuBounce)"
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
        lastResignKeyDate = Date()

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
    /// state to disk, invokes view-layer teardown callback, then disconnects
    /// the session if this was the last window for the connection.
    func handleWindowWillClose() {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[close] coordinator.handleWindowWillClose connId=\(self.connectionId, privacy: .public) tabs=\(self.tabManager.tabs.count)"
        )

        // Persist remaining non-preview tabs synchronously. saveNowSync writes
        // directly without spawning a Task — required here because the window
        // is closing and we cannot rely on async tasks being serviced.
        let persistableTabs = tabManager.tabs.filter { !$0.isPreview }
        if persistableTabs.isEmpty {
            // Empty → clear saved state so next open shows a default empty window.
            persistence.saveNowSync(tabs: [], selectedTabId: nil)
        } else {
            let normalizedSelectedId =
                persistableTabs.contains(where: { $0.id == tabManager.selectedTabId })
                ? tabManager.selectedTabId : persistableTabs.first?.id
            persistence.saveNowSync(tabs: persistableTabs, selectedTabId: normalizedSelectedId)
        }

        // Cancel the pending eviction task before teardown drops it.
        evictionTask?.cancel()
        evictionTask = nil

        // View-layer teardown (e.g. rightPanelState cleanup) before coordinator
        // teardown so its SwiftUI state is released first.
        onWindowWillClose?()

        teardown()

        // Disconnect is handled by WindowLifecycleMonitor.handleWindowClose,
        // which fires after this delegate method. It removes the window entry
        // first, then checks if any remain for the connection, then disconnects.

        Self.lifecycleLogger.info(
            "[close] coordinator.handleWindowWillClose done connId=\(self.connectionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }
}
