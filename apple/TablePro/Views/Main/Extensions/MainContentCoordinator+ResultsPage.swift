//
//  MainContentCoordinator+ResultsPage.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// The Message and Summary pages unmount the grid, so a cell being edited is committed first, as a view mode
    /// switch commits it.
    func showResultsPage(_ page: ResultsPage, in tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.display.resultsPage != page else { return }
        commitActiveGridEdit()
        tabManager.mutate(tabId: tabId) { $0.display.resultsPage = page }
    }

    /// A result chosen from the run tabs, their pull-down or a Summary row. The switch keeps its discard prompt.
    func showRunResult(_ resultSetId: UUID, in tabId: UUID) {
        showResultsPage(.result, in: tabId)
        switchActiveResultSet(to: resultSetId, in: tabId)
    }

    /// What the result tab row and the result pull-down do for one tab.
    func resultSetActions(forTab tabId: UUID) -> ResultSetActions {
        ResultSetActions(
            activate: { [weak self] in self?.switchActiveResultSet(to: $0, in: tabId) },
            togglePin: { [weak self] in self?.togglePinResultSet(id: $0) },
            compare: { [weak self] in self?.compareResultSet(id: $0) },
            close: { [weak self] in self?.closeResultSet(id: $0) },
            closeOthers: { [weak self] in self?.closeOtherResultSets(keeping: $0) }
        )
    }

    /// The same actions for the run tabs, where choosing a result also brings its page to the front.
    func runTabActions(forTab tabId: UUID) -> QueryRunTabActions {
        let resultActions = resultSetActions(forTab: tabId)
        return QueryRunTabActions(
            showPage: { [weak self] in self?.showResultsPage($0, in: tabId) },
            results: ResultSetActions(
                activate: { [weak self] in self?.showRunResult($0, in: tabId) },
                togglePin: resultActions.togglePin,
                compare: resultActions.compare,
                close: resultActions.close,
                closeOthers: resultActions.closeOthers
            )
        )
    }
}
