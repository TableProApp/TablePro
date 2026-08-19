//
//  FindCoordinator.swift
//  TablePro
//

import Foundation
import SwiftUI

@MainActor @Observable
final class FindCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator
    @ObservationIgnored private var searchDebounce: DispatchWorkItem?

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    var selectedTabFindState: TabFindState? {
        parent.tabManager.selectedTab?.findState
    }

    func show() {
        mutateSelectedTabFindState { $0.isVisible = true }
    }

    func dismiss() {
        searchDebounce?.cancel()
        searchDebounce = nil
        mutateSelectedTabFindState {
            $0.isVisible = false
            $0.term = ""
            $0.clearMatches()
        }
        parent.dataTabDelegate?.tableViewCoordinator?.applyFindMatch(nil)
    }

    /// The scan is synchronous and main-actor bound, and a wide table is the expensive case:
    /// CLAUDE.md flags 500+ columns as the real data-grid cost, so a 1,000-row page is hundreds of
    /// thousands of range searches per keystroke. Coalescing means one scan per pause, not per key.
    func setTerm(_ term: String) {
        mutateSelectedTabFindState { $0.term = term }
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func stepForward() {
        mutateSelectedTabFindState { $0.stepForward() }
        syncGridToCurrentMatch()
    }

    func stepBackward() {
        mutateSelectedTabFindState { $0.stepBackward() }
        syncGridToCurrentMatch()
    }

    /// Promotes the term into a server-side filter so the answer covers rows this page never
    /// loaded. It builds its own filter rows rather than going through `addFilter`, which would
    /// consult the user's default-column setting, and it never touches the filters they already
    /// applied.
    func escalateToAllRows() {
        guard let tab = parent.tabManager.selectedTab else { return }
        let term = tab.findState.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
        let searchable = buffer.columns.indices.filter { index in
            guard index < buffer.columnTypes.count else { return true }
            return FindMatcher.isServerSearchable(buffer.columnTypes[index])
        }
        guard !searchable.isEmpty else { return }

        dismiss()
        parent.filterCoordinator.applyCrossColumnSearch(
            term: term,
            columns: searchable.map { buffer.columns[$0] }
        )
    }

    func runSearch() {
        guard let tab = parent.tabManager.selectedTab,
              let grid = parent.dataTabDelegate?.tableViewCoordinator
        else { return }

        let term = tab.findState.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            invalidateMatches()
            grid.applyFindMatch(nil)
            return
        }

        let matches = grid.runFind(term: term)
        let anchor = grid.selectedDisplayRow ?? 0
        mutateSelectedTabFindState { state in
            state.matches = matches
            state.scope = self.scope(for: tab)
            state.currentMatchIndex = FindMatcher.nearestMatchIndex(to: anchor, in: matches)
        }
        syncGridToCurrentMatch()
    }

    private func syncGridToCurrentMatch() {
        guard let grid = parent.dataTabDelegate?.tableViewCoordinator else { return }
        grid.applyFindMatch(parent.tabManager.selectedTab?.findState.currentMatch)
    }

    /// Rows were replaced underneath the find bar, so the match list describes rows that no
    /// longer exist. Keep the term and the bar, drop what is stale.
    func invalidateMatches() {
        mutateSelectedTabFindState { $0.clearMatches() }
    }

    /// `hasMoreRows` is the query-tab truncation flag and is never set for a table tab, which pages
    /// through `currentPage`/`totalPages` instead. Reading only that flag made every table tab claim
    /// its page was the whole table, which is the exact answer this feature exists to avoid.
    func scope(for tab: QueryTab) -> FindScope {
        let loadedRowCount = parent.tabSessionRegistry.tableRows(for: tab.id).rows.count
        let hasUnloadedRows = tab.pagination.hasMoreRows
            || tab.pagination.canGoToNextPage(loadedRowCount: loadedRowCount)
        return hasUnloadedRows ? .pageOfMore : .allRowsLoaded
    }

    private func mutateSelectedTabFindState(_ mutate: (inout TabFindState) -> Void) {
        guard let index = parent.tabManager.selectedTabIndex else { return }
        var newState = parent.tabManager.tabs[index].findState
        mutate(&newState)
        parent.tabManager.mutate(at: index) { $0.findState = newState }
    }
}
