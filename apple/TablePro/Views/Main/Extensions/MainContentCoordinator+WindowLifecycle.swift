//
//  MainContentCoordinator+WindowLifecycle.swift
//  TablePro
//
//  windowDidBecomeKey stays light per Apple's docs; visibility-scoped lazy load lives in MainEditorContentView's .task(id:).
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

extension MainContentCoordinator {
    // MARK: - Window Delegate Dispatch

    // The one query action here: a restored background tab loads its data the first time its window becomes key.
    func handleWindowDidBecomeKey() {
        let t0 = Date()
        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey connId=\(self.connectionId, privacy: .public) selectedTabId=\(self.tabManager.selectedTabId?.uuidString ?? "nil", privacy: .public)"
        )
        isKeyWindow = true

        consumeDeferredRestoreLoadIfNeeded()
        refreshSourceFileDiskChanges()

        browseCursorCoordinator.followVisibleContainerOnActivation()
        syncSidebarObjectSelection()
        announceActiveTabToVoiceOver()

        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey done connId=\(self.connectionId, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

    func handleWindowDidResignKey() {
        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidResignKey connId=\(self.connectionId, privacy: .public)"
        )
        isKeyWindow = false
    }

    // Synchronous on purpose: no grace period, no delayed Task.
    func handleWindowWillClose() {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[close] coordinator.handleWindowWillClose connId=\(self.connectionId, privacy: .public) tabs=\(self.tabManager.tabs.count)"
        )

        // Never clears: closing a window says nothing about keeping its tabs; only closeTabsByUser discards saved state.
        flushColumnLayoutPersistence()
        if !MainContentCoordinator.isAppTerminating, !isTearingDown {
            persistence.saveAggregatedSync()
        }

        trailingPaneState?.teardown()

        teardown()

        Self.lifecycleLogger.info(
            "[close] coordinator.handleWindowWillClose done connId=\(self.connectionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

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

    @discardableResult
    func selectTabAndFocusWindow(_ tabId: UUID) -> Bool {
        tabManager.selectedTabId = tabId
        return focusWindow()
    }

    @discardableResult
    func focusWindow() -> Bool {
        guard let windowId,
              let window = WindowLifecycleMonitor.shared.window(for: windowId) else { return false }
        (window.contentViewController as? MainSplitViewController)?.selectHostedConnection(connectionId)
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: - Sidebar Sync

    // Every input the mark depends on (tab, container, objects, key window) calls this; skipping one left a stale mark (#2217).
    func syncSidebarObjectSelection() {
        let selectedTab = tabManager.selectedTab
        let selection = SidebarObjectSelection.resolve(
            tabTableName: selectedTab?.tableContext.tableName,
            tabScope: selectedTab.flatMap { scope(for: $0) },
            browseScope: browseScope,
            tables: services.databaseManager.session(for: connectionId)?.tables ?? []
        )
        guard case .mark(let target) = selection,
              windowSidebarState.selectedTables != target else { return }
        windowSidebarState.selectTables(target)
    }

    // MARK: - Lazy Load

    // Every path that declines the load must lower the flag, or the bar keeps a spinner; an in-flight load leaves it alone.
    func declineTableLoad(for tabId: UUID) {
        tabManager.mutate(tabId: tabId) { $0.pagination.isLoading = false }
    }

    func lazyLoadCurrentTabIfNeeded(trigger: TableLoadTrigger = .userInitiated) {
        guard let tab = tabManager.selectedTab else { return }
        guard deferredRestoreLoadTabId != tab.id else {
            declineTableLoad(for: tab.id)
            return
        }
        guard canAutoLoadTableTab(tab) else {
            declineTableLoad(for: tab.id)
            return
        }

        let tracer = TableLoadTracer.shared
        let carriedToken = tracer.activeToken(for: tab.id)
        let traceToken = carriedToken ?? tracer.begin(
            tabId: tab.id,
            table: tab.tableContext.tableName ?? "",
            origin: trigger == .restore ? .restore : .programmatic,
            environment: tableLoadEnvironment,
            connectionId: connectionId
        )

        // The in-flight load closes the trace it owns; only a trace this call minted is closed here.
        func noteLoadAlreadyInFlight() {
            guard carriedToken == nil else { return }
            tracer.anomaly(.loadAlreadyInFlight, token: traceToken)
            tracer.finish(token: traceToken, outcome: .loadAlreadyInFlight)
        }

        guard tableLoadTasks[tab.id] == nil else {
            noteLoadAlreadyInFlight()
            return
        }

        clearAbandonedExecutingFlagIfNeeded(for: tab)

        // The task slot empties once the load hands off to execution, so the registry is asked too, or a duplicate load ran (#2342).
        guard !tabExecution.isBusy(tab.id) else {
            noteLoadAlreadyInFlight()
            return
        }

        guard let session = DatabaseManager.shared.session(for: connectionId),
              session.isConnected else {
            tracer.anomaly(.connectionNotReady, token: traceToken)
            tracer.finish(token: traceToken, outcome: .notConnected)
            parkedTableLoad = ParkedTableLoad(tabId: tab.id, trigger: trigger)
            declineTableLoad(for: tab.id)
            return
        }

        let tabId = tab.id
        tracer.stage(.lazyLoadScheduled, token: traceToken)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.tableLoadTasks[tabId]?.token == token {
                    self.tableLoadTasks[tabId] = nil
                }
            }
            await self.openTableTabQuery(tabId: tabId, trigger: trigger)
            if let queryTask = self.queryTasks.task(for: tabId) {
                await queryTask.value
            }
        }
        tableLoadTasks[tabId] = (token, task)
    }

    func cancelTableLoad(for tabId: UUID) {
        tableLoadTasks[tabId]?.task.cancel()
        tableLoadTasks[tabId] = nil
    }

    // Ends the deferral whatever tab is selected: a link or agent can switch tabs first, and a leftover deferral blocked loads.
    func consumeDeferredRestoreLoadIfNeeded() {
        guard isKeyWindow, let deferredId = deferredRestoreLoadTabId else { return }
        deferredRestoreLoadTabId = nil
        guard deferredId == tabManager.selectedTabId else { return }
        lazyLoadCurrentTabIfNeeded(trigger: .restore)
    }

    // The parked trigger goes only to the tab that parked it: run against another selected tab, it executed a query tab's SQL.
    func loadSelectedTableTabAfterConnect() {
        let parked = parkedTableLoad
        parkedTableLoad = nil
        let trigger = parked.flatMap { $0.tabId == tabManager.selectedTabId ? $0.trigger : nil }
        lazyLoadCurrentTabIfNeeded(trigger: trigger ?? .userInitiated)
    }

    // Rows a tab holds stay until the user asks for others; only a first load or a change TablePro made to the table loads here.
    func canAutoLoadTableTab(_ tab: QueryTab) -> Bool {
        guard tab.tabType == .table else { return false }
        guard tab.execution.errorMessage == nil else { return false }
        guard !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let hasLoaded = tab.execution.lastExecutedAt != nil
            || !tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty
        guard !hasLoaded || tabSessionRegistry.isStale(tab.id) else { return false }

        return !holdsUnsavedWork(tab)
    }

    private func clearAbandonedExecutingFlagIfNeeded(for tab: QueryTab) {
        guard tabExecution.isExecuting(tab.id), !queryTasks.hasTask(for: tab.id) else { return }
        TableLoadTracer.shared.anomaly(
            .preparationAbandoned,
            tabId: tab.id,
            detail: "clearedAbandonedClaim"
        )
        reportEndedExecutions(tabExecution.invalidate(tab.id, reason: .abandoned).map { [$0] } ?? [])
    }
}
