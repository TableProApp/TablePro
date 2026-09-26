//
//  MainContentCoordinator+TableRowsRefresh.swift
//  TablePro
//
//  What a window does with a change made to the rows or the definition of tables it shows.
//

import Combine
import Foundation

extension MainContentCoordinator {
    /// Marks every addressed table tab stale, reloads the selected one now when the plan allows, and
    /// has the structure of each fetched again.
    ///
    /// Nothing here asks a question. The change was made somewhere else, maybe in another window, so
    /// a tab holding edits or an open cell overlay keeps them, and its rows, until they are gone, and
    /// a structure holding staged edits keeps those. The tab that made the change is left out of the
    /// rows plan only: it reloads its own rows, and its structure is fetched like any other.
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

    /// Runs the reload the selected tab put off while its cell overlay or its edits were in the way,
    /// once they are gone. The plan is asked again rather than remembered, so whatever the user
    /// started meanwhile, a new overlay, an edit or a load of the tab's own, still stands in the way.
    /// A grid torn down with its window closes its overlay too, and that starts nothing.
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

    /// Edits go without a Discard too: the last one undone, a cell typed back to what it held, a
    /// deleted row restored. Each leaves the change manager clean, which is when a reload put off for
    /// them can run. Heard a turn later, because the manager publishes before it stores the value, and
    /// a switch or a save that cleaned it has started the tab's own load by then.
    func resumeWhenEditsClear() -> AnyCancellable {
        changeManager.$hasChanges
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resumeDeferredTableRefresh() }
    }

    /// A change that names no single table reaches every table tab in its scope, and can have
    /// changed the columns of a table no tab shows, so every column list cached for scoping goes.
    func applyDataRefresh(_ request: DataRefreshRequest) {
        guard request.connectionId == connectionId else { return }
        schemaColumns.removeAll()
        refreshTableTabs(for: TableFreshness.Change(extent: .definition, at: request.changedAt)) {
            request.reaches(tabScope: scope(for: $0))
        }
    }

    /// Structure the user is not editing is fetched again: now for the one on screen, on its next
    /// mount for the rest. A structure holding staged edits keeps them and the old baseline, and is
    /// fetched once they are applied, undone or discarded.
    private func refreshStructure(ofTabs tabs: [QueryTab]) {
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

    /// The named table's column list, cached for scoping a tab opened on it later.
    func forgetSchemaColumns(of change: DatabaseObjectChange) {
        schemaColumns.remove(schemaColumnsKey(change.name, scope: change.scope))
    }

    /// The columns cached for building a table's column-scoped query describe the definition before
    /// the change, and a reload builds its SQL from them before it fetches anything: kept, they would
    /// name a dropped column in the select list and leave out an added one. The reload's own
    /// definition fetch stores the new set.
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
        let holdsEdits = changeManager.hasChanges
            || tab.pendingChanges.hasChanges
            || dataTabDelegate?.tableViewCoordinator?.hasOpenCellOverlay == true
        return TableRowsRefreshPlan.SelectedTabState(id: tab.id, holdsEdits: holdsEdits, load: selectedTabLoad(tab.id))
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

    /// Written only when there is a count to retire, because every write fires `tabs`' `didSet`.
    private func retireDerivedRowCountIfSet(forTab tabId: UUID) {
        guard let pagination = tabManager.tabs.first(where: { $0.id == tabId })?.pagination,
              pagination.totalRowCount != nil || pagination.isApproximateRowCount else { return }
        tabManager.mutate(tabId: tabId) { $0.pagination.retireDerivedRowCount() }
    }
}
