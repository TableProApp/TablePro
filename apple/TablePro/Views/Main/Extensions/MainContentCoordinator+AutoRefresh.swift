//
//  MainContentCoordinator+AutoRefresh.swift
//  TablePro
//

import Combine
import Foundation

// One per window: only the selected table tab ticks, so a switch, a close or a move ends one wait and starts the next.
@MainActor
final class TableAutoRefreshSchedule {
    var clock: any Clock<Duration> = ContinuousClock()
    var visibility: @MainActor (OperationOwner, UUID) -> ResultVisibility = { owner, connectionId in
        ResultVisibilityResolver.resolve(owner: owner, connectionId: connectionId)
    }
    fileprivate(set) var task: Task<Void, Never>?
    fileprivate var selectionCancellable: AnyCancellable?

    var isRunning: Bool { task != nil }
}

extension MainContentCoordinator {
    func observeSelectionForAutoRefresh() {
        autoRefresh.selectionCancellable = tabManager.$selectedTabId
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restartAutoRefresh() }
    }

    func setAutoRefreshInterval(_ interval: TableAutoRefreshInterval, forTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.tabType == .table else { return }
        if tab.autoRefreshInterval != interval || tab.autoRefreshPause != nil {
            tabManager.mutate(tabId: tabId) { tab in
                tab.autoRefreshInterval = interval
                tab.autoRefreshPause = nil
            }
        }
        guard tabId == tabManager.selectedTabId else { return }
        restartAutoRefresh()
    }

    func restartAutoRefresh() {
        autoRefresh.task?.cancel()
        autoRefresh.task = nil
        guard !isTearingDown,
              let tab = tabManager.selectedTab,
              tab.tabType == .table,
              tab.autoRefreshInterval.isOn else { return }
        let tabId = tab.id
        let clock = autoRefresh.clock
        // Weak between ticks, so a wait never keeps a closed window's coordinator alive.
        autoRefresh.task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.awaitAutoRefreshLoad(tabId)
                guard let interval = self?.autoRefreshInterval(ofTab: tabId), interval.isOn else { return }
                do {
                    try await clock.sleep(for: interval.duration)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard await runAutoRefreshTick(tabId) else { return }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefresh.task?.cancel()
        autoRefresh.task = nil
        autoRefresh.selectionCancellable = nil
    }

    func autoRefreshGate(forTab tabId: UUID) -> TableAutoRefreshGate {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return TableAutoRefreshGate(isTableTab: false)
        }
        let visibility = autoRefresh.visibility(operationOwner(tabId: tabId), connectionId)
        let model = existingGridModel(forTab: tabId)
        let database = scope(for: tab)?.database ?? browseDatabaseName
        var gate = TableAutoRefreshGate()
        gate.isTableTab = tab.tabType == .table && tab.tableContext.tableName != nil
        gate.hasLoaded = tab.execution.lastExecutedAt != nil
        gate.windowIsVisible = visibility.ownerWindowIsVisible
        gate.isSelectedInWindow = visibility.ownerIsSelectedInWindow && tabManager.selectedTabId == tabId
        gate.isConnected = services.databaseManager.session(for: connectionId)?.reportedStatus == .connected
        gate.viewMode = tab.display.resultsViewMode
        // Read only: a read inside the user's transaction sees its snapshot, and a failure aborts it on PostgreSQL.
        gate.holdsTransaction = services.databaseManager.sessionTransactions
            .transactionState(connectionId: connectionId, container: database) != nil
        gate.holdsUnsavedWork = holdsUnsavedWork(tab)
        gate.hasSidebarDataWork = commandActions?.hasDataWork ?? false
        gate.isEditingCell = model?.isEditing ?? false
        gate.gridHoldsTransientUI = model?.holdsTransientUI ?? false
        gate.gridIsTrackingInteraction = model?.isTrackingInteraction ?? false
        gate.inspectorHoldsValueWindow = trailingPaneState.map { InspectorPopOutRegistry.holdsWindow(openedFrom: $0) } ?? false
        gate.load = tabExecution.isBusy(tabId) || tableLoadTasks[tabId] != nil ? .busy : .idle
        gate.isCountPending = tab.pagination.isCountPending
        gate.isLoadingMore = tab.pagination.isLoadingMore
        gate.showsSafeModePrompt = isShowingSafeModePrompt
        gate.hasSelection = model.map { !$0.selection.affectedRows.isEmpty } ?? false
        gate.hasPrimaryKey = !tab.tableContext.primaryKeyColumns.isEmpty
        return gate
    }

    func autoRefreshHeldByTransientUI(_ tabId: UUID) -> Bool {
        let gate = autoRefreshGate(forTab: tabId)
        return gate.gridHoldsTransientUI || gate.inspectorHoldsValueWindow || gate.isEditingCell
    }

    private func autoRefreshInterval(ofTab tabId: UUID) -> TableAutoRefreshInterval? {
        guard tabManager.selectedTabId == tabId else { return nil }
        return tabManager.tabs.first { $0.id == tabId }?.autoRefreshInterval
    }

    // Once, not in a loop: a finished task its owner has not retired yet would spin the main actor.
    private func awaitAutoRefreshLoad(_ tabId: UUID) async {
        if let scheduled = tableLoadTasks[tabId]?.task {
            await scheduled.value
        }
        if let running = queryTasks.task(for: tabId) {
            await running.value
        }
    }

    // False ends the schedule: the tab is gone or no longer selected, or the gate stopped it.
    private func runAutoRefreshTick(_ tabId: UUID) async -> Bool {
        // A retarget keeps the tab id and turns the interval off while this wait slept.
        guard autoRefreshInterval(ofTab: tabId)?.isOn == true else { return false }
        switch autoRefreshGate(forTab: tabId).decision {
        case .stop:
            endAutoRefresh(forTab: tabId)
            return false
        case .wait(let pause):
            recordAutoRefreshPause(pause.help == nil ? nil : pause, forTab: tabId)
            return true
        case .refresh:
            recordAutoRefreshPause(nil, forTab: tabId)
        }
        // Not runQuery, which commits an open edit, nor reloadTableTab, which retires the count.
        if let load = executeTableTabQueryDirectly(trigger: .autoRefresh, viewport: .keepPlace)
            ?? queryTasks.task(for: tabId) {
            await load.value
        }
        guard !Task.isCancelled else { return false }
        var settled = autoRefreshGate(forTab: tabId)
        settled.previousTickFailed = tabManager.tabs.first { $0.id == tabId }?.execution.errorMessage != nil
        guard settled.decision != .stop else {
            endAutoRefresh(forTab: tabId)
            return false
        }
        return true
    }

    // The tab keeps its own inline error; only the interval goes.
    private func endAutoRefresh(forTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.autoRefreshInterval.isOn || tab.autoRefreshPause != nil else { return }
        tabManager.mutate(tabId: tabId) { tab in
            tab.autoRefreshInterval = .off
            tab.autoRefreshPause = nil
        }
    }

    // Written only on change: every tab write re-renders the window.
    private func recordAutoRefreshPause(_ pause: TableAutoRefreshPause?, forTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.autoRefreshPause != pause else { return }
        tabManager.mutate(tabId: tabId) { $0.autoRefreshPause = pause }
    }
}
