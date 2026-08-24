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
    /// sidebar selection to the active tab. The one query-related action here is
    /// consuming a deferred restore load: a restored background tab loads its data
    /// the first time its window becomes key. All other lazy-load is owned by
    /// `MainEditorContentView`'s `.task(id:)` modifier.
    func handleWindowDidBecomeKey() {
        let t0 = Date()
        Self.lifecycleLogger.debug(
            "[switch] coordinator.handleWindowDidBecomeKey connId=\(self.connectionId, privacy: .public) selectedTabId=\(self.tabManager.selectedTabId?.uuidString ?? "nil", privacy: .public)"
        )
        isKeyWindow = true
        evictionTask?.cancel()
        evictionTask = nil

        consumeDeferredRestoreLoadIfNeeded()

        recordSelectedTabContainer()
        syncSidebarObjectSelection()
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

        /// Never clears: a window closing says nothing about whether the user wants these tabs
        /// kept, and every connection in the window reaches here. Discarding saved state is
        /// `closeTabsByUser`'s job alone.
        dataTabDelegate?.tableViewCoordinator?.flushPendingColumnLayoutPersistence()
        if !MainContentCoordinator.isAppTerminating, !isTearingDown {
            persistence.saveAggregatedSync()
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

    func selectTabAndFocusWindow(_ tabId: UUID) {
        tabManager.selectedTabId = tabId
        focusWindow()
    }

    func focusWindow() {
        guard let windowId,
              let window = WindowLifecycleMonitor.shared.window(for: windowId) else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Sidebar Sync

    /// Mark the object the selected tab is showing in this window's object tree, or nothing when
    /// that tab belongs to a container the tree is not listing. Reads tables fresh from the
    /// DatabaseManager because the schema load is async and may complete after focus changes.
    ///
    /// The mark is a function of four inputs, so every one of them calls this: the selected tab,
    /// the browsed container, the object list, and the window becoming key. Recomputing on only
    /// some of them is what left a stale mark on a row in another database (#2217).
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

    /// Lowers the flag `discardRowsForRetarget` raised, for a load that is not going to run.
    ///
    /// The flag is raised synchronously with the row buffer being emptied, so the bar never reads a
    /// cleared tab as a settled empty result. Every path that then declines to start the load has to
    /// lower it again, or the bar keeps a spinner and a fully disabled pagination cluster for a tab
    /// that is not loading anything, until the next successful load or `Cmd+.`. A load that is
    /// already in flight is not a decline, and must leave the flag alone.
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

        /// A trace the in-flight load still owns stays open, because that load is the one that will
        /// close it. Only a trace this call minted is closed here.
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

        /// The task slot above stops answering the moment the load hands off to an execution:
        /// `executeQueryInternal` supersedes, and `supersedeExecution` nils the very slot held by
        /// the task it is running inside. Every later trigger for the same navigation then found an
        /// empty slot and scheduled a second identical load, whose predecessor took the successor's
        /// claim down with it on the way out (#2342). The registry owns the other half of the same
        /// question, so both halves are asked, and neither alone is enough.
        guard !tabExecution.isBusy(tab.id) else {
            noteLoadAlreadyInFlight()
            return
        }

        guard let session = DatabaseManager.shared.session(for: connectionId),
              session.isConnected else {
            tracer.anomaly(.connectionNotReady, token: traceToken)
            tracer.finish(token: traceToken, outcome: .notConnected)
            pendingLoadTrigger = trigger
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

    func consumeDeferredRestoreLoadIfNeeded() {
        guard isKeyWindow else { return }
        guard let deferredId = deferredRestoreLoadTabId,
              deferredId == tabManager.selectedTabId else { return }
        deferredRestoreLoadTabId = nil
        lazyLoadCurrentTabIfNeeded(trigger: .restore)
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
        guard tabExecution.isExecuting(tab.id), currentQueryTask == nil else { return }
        TableLoadTracer.shared.anomaly(
            .preparationAbandoned,
            tabId: tab.id,
            detail: "clearedAbandonedClaim"
        )
        reportEndedExecutions(tabExecution.invalidate(tab.id, reason: .abandoned).map { [$0] } ?? [])
    }
}
