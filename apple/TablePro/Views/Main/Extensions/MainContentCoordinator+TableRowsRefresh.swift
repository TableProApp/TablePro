//
//  MainContentCoordinator+TableRowsRefresh.swift
//  TablePro
//
//  What a window does with a change made to the rows or the definition of tables it shows.
//

import Combine
import Foundation

extension MainContentCoordinator {
    // Asks nothing: the change came from elsewhere, so tabs with edits or overlays keep them; the source tab reloads its own rows.
    func refreshTableTabs(
        for change: TableFreshness.Change,
        excluding originTabId: UUID? = nil,
        where isAddressed: (QueryTab) -> Bool
    ) {
        let addressed = tabManager.tabs.filter { $0.tabType == .table && isAddressed($0) }
        if change.extent == .definition {
            forgetSchemaColumns(ofTabs: addressed)
        }
        let selectedState = selectedTabRefreshState
        let plan = TableRowsRefreshPlan(
            tabs: tabManager.tabs,
            selectedTab: selectedState,
            change: change,
            excludingTabId: originTabId,
            where: isAddressed
        )
        let selectedId = tabManager.selectedTabId
        for tabId in plan.staleTabIds {
            tabSessionRegistry.recordChange(change, for: tabId)
            if tabId != selectedId {
                retireDerivedRowCountIfSet(forTab: tabId)
            }
        }
        perform(plan.selectedTabAction, selectedState: selectedState)
        refreshStructure(ofTabs: addressed)
    }

    // The plan is asked again, not remembered, so anything the user started meanwhile still blocks the reload.
    func resumeDeferredTableRefresh() {
        guard !isTearingDown,
              let selectedState = selectedTabRefreshState,
              let tab = tabManager.selectedTab,
              tab.tabType == .table,
              let change = tabSessionRegistry.pendingChange(for: tab.id) else { return }
        perform(
            TableRowsRefreshPlan.resumedAction(for: tab, state: selectedState, owing: change),
            selectedState: selectedState
        )
    }

    // Heard a turn later: the manager publishes before it stores, and by then a cleaning switch or save has started the load.
    func resumeWhenEditsClear() -> AnyCancellable {
        changeManager.$hasChanges
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resumeDeferredTableRefresh() }
    }

    // A scope-wide change can alter columns of tables no tab shows, so every cached column list goes.
    func applyDataRefresh(_ request: DataRefreshRequest) {
        guard request.connectionId == connectionId else { return }
        schemaColumns.removeAll()
        refreshTableTabs(for: TableFreshness.Change(extent: .definition, at: request.changedAt)) {
            request.reaches(tabScope: scope(for: $0))
        }
    }

    // A structure with staged edits keeps them and the old baseline until they are applied, undone or discarded.
    func refreshStructure(ofTabs tabs: [QueryTab]) {
        let selectedId = tabManager.selectedTabId
        for tab in tabs {
            guard let session = structureSessions[tab.id] else { continue }
            let isOnScreen = tab.id == selectedId && tab.display.resultsViewMode == .structure
            if isOnScreen, !session.changeManager.hasChanges, let refresh = structureActions?.refresh {
                refresh()
            } else {
                session.markStructureStale()
            }
        }
    }

    func forgetSchemaColumns(of change: DatabaseObjectChange) {
        schemaColumns.remove(schemaColumnsKey(change.name, scope: change.scope))
    }

    // A reload builds its SQL from these cached columns before fetching, so stale ones would select a dropped column.
    private func forgetSchemaColumns(ofTabs tabs: [QueryTab]) {
        for tab in tabs {
            guard let tableName = tab.tableContext.tableName else { continue }
            schemaColumns.remove(schemaColumnsKey(tableName, scope: scope(for: tab)))
        }
    }

    private func perform(
        _ action: TableRowsRefreshPlan.SelectedTabAction,
        selectedState: TableRowsRefreshPlan.SelectedTabState?
    ) {
        switch action {
        case .noReload:
            break
        case .reloadNow:
            guard let index = tabManager.selectedTabIndex else { return }
            reloadTableTab(at: index)
        case .reloadBehindStructure:
            guard let selectedId = selectedState?.id else { return }
            if case .running = selectedState?.load {
                stopExecution(for: selectedId)
                cancelTableLoad(for: selectedId)
            }
            retireDerivedRowCountIfSet(forTab: selectedId)
            lazyLoadCurrentTabIfNeeded()
        }
    }

    private var selectedTabRefreshState: TableRowsRefreshPlan.SelectedTabState? {
        guard let tab = tabManager.selectedTab else { return nil }
        return TableRowsRefreshPlan.SelectedTabState(
            id: tab.id,
            holdsEdits: holdsUnsavedWork(tab),
            load: selectedTabLoad(tab.id)
        )
    }

    // The one answer for every reload path, the lazy load included: an open cell counts, or a reload drops what is typed in it.
    func holdsUnsavedWork(_ tab: QueryTab) -> Bool {
        if tab.pendingChanges.hasChanges { return true }
        guard tab.id == changeManagerTabId else { return false }
        return changeManager.hasChanges || isEditingActiveGrid
    }

    private func selectedTabLoad(_ tabId: UUID) -> TableRowsRefreshPlan.SelectedTabLoad {
        if let startedAt = tabExecution.startedAt(tabId) {
            return .running(startedAt: startedAt)
        }
        if tableLoadTasks[tabId] != nil {
            return .scheduled
        }
        return tabExecution.isBusy(tabId) ? .extending : .idle
    }

    // Written only when set, because every write fires tabs' didSet.
    private func retireDerivedRowCountIfSet(forTab tabId: UUID) {
        guard let pagination = tabManager.tabs.first(where: { $0.id == tabId })?.pagination,
              pagination.totalRowCount != nil || pagination.isApproximateRowCount else { return }
        tabManager.mutate(tabId: tabId) { $0.pagination.retireDerivedRowCount() }
    }
}
