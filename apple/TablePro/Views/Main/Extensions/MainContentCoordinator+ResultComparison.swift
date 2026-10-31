//
//  MainContentCoordinator+ResultComparison.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    var canCompareActiveResult: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .query,
              tab.display.resultsViewMode != .structure,
              let active = tab.display.activeResultSet else { return false }
        return isComparable(active, in: tab)
    }

    func compareActiveResult() {
        guard canCompareActiveResult, let activeId = tabManager.selectedTab?.display.activeResultSet?.id else { return }
        compareResultSet(id: activeId)
    }

    func compareResultSet(id: UUID) {
        guard let tab = tabManager.selectedTab, tab.tabType == .query,
              let resultSet = tab.display.resultSets.first(where: { $0.id == id }),
              let left = comparisonSide(of: resultSet, in: tab) else { return }
        let leftId = resultSet.id
        let tabId = tab.id
        let partner = Self.defaultComparisonPartner(
            of: leftId,
            among: tab.display.resultSets.filter { isComparable($0, in: tab) }.map(\.id)
        )
        let model = ResultComparisonModel(left: left, preferredRightId: partner) {
            Self.comparisonCandidates(excluding: leftId, homeTabId: tabId)
        }
        ResultComparisonWindowController.open(model: model)
    }

    // The newest result is compared with the one before it, so "run, pin, run again" lands on the pinned run.
    static func defaultComparisonPartner(of activeId: UUID, among ids: [UUID]) -> UUID? {
        guard let position = ids.firstIndex(of: activeId) else { return ids.last }
        guard position == ids.count - 1 else { return ids.last }
        return position > 0 ? ids[position - 1] : nil
    }

    // The chooser's own name for the result, so a counted name never sits beside a different count.
    static func comparisonTitle(of resultSet: ResultSet, in display: TabDisplayState) -> String {
        guard let index = display.resultSets.firstIndex(where: { $0.id == resultSet.id }) else { return resultSet.label }
        return ResultSetMenuModel.displayLabel(at: index, in: display.resultSets.map(\.label))
    }

    // Every result of the tab the comparison starts from, and every pinned result of any other query tab.
    static func comparisonCandidates(excluding leftId: UUID, homeTabId: UUID) -> [ResultComparisonCandidate] {
        var home: [ResultComparisonCandidate] = []
        var others: [ResultComparisonCandidate] = []
        for coordinator in WindowManager.shared.hostedCoordinators() {
            for tab in coordinator.tabManager.tabs where tab.tabType == .query {
                let isHome = tab.id == homeTabId
                let tabId = tab.id
                for resultSet in tab.display.resultSets
                    where resultSet.id != leftId && (isHome || resultSet.isPinned)
                    && coordinator.isComparable(resultSet, in: tab) {
                    let resultId = resultSet.id
                    let candidate = ResultComparisonCandidate(
                        id: resultId,
                        title: comparisonTitle(of: resultSet, in: tab.display),
                        group: isHome ? String(localized: "This Tab") : coordinator.comparisonDetail(for: tab),
                        isPinned: resultSet.isPinned,
                        read: { [weak coordinator] in
                            coordinator?.comparisonSide(ofResult: resultId, inTab: tabId)
                        }
                    )
                    if isHome {
                        home.append(candidate)
                    } else {
                        others.append(candidate)
                    }
                }
            }
        }
        return home + others
    }

    func comparisonSide(ofResult resultId: UUID, inTab tabId: UUID) -> ResultComparisonSide? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let resultSet = tab.display.resultSets.first(where: { $0.id == resultId }) else { return nil }
        return comparisonSide(of: resultSet, in: tab)
    }

    func comparisonSide(of resultSet: ResultSet, in tab: QueryTab) -> ResultComparisonSide? {
        guard !resultSet.isExplainResult else { return nil }
        let rows = comparisonRows(of: resultSet, in: tab)
        guard !rows.columns.isEmpty else { return nil }
        let primaryKey: [String]
        if let origin = resultSet.origin, origin.keysResolved, origin.tableName?.isEmpty == false {
            primaryKey = origin.primaryKeyColumns
        } else {
            primaryKey = []
        }
        return ResultComparisonSide(
            title: Self.comparisonTitle(of: resultSet, in: tab.display),
            detail: comparisonDetail(for: tab),
            columns: rows.columns,
            columnTypes: rows.columnTypes,
            rows: rows.rows,
            isTruncated: resultSet.isTruncated,
            primaryKeyColumns: primaryKey
        )
    }

    func comparisonDetail(for tab: QueryTab) -> String {
        String(format: String(localized: "%1$@ (%2$@)"), tab.title, connection.name)
    }

    func isComparable(_ resultSet: ResultSet, in tab: QueryTab) -> Bool {
        !resultSet.isExplainResult && !comparisonRows(of: resultSet, in: tab).columns.isEmpty
    }

    // The active result's rows live in the tab's shared buffer, which page loads and Fetch All write to.
    private func comparisonRows(of resultSet: ResultSet, in tab: QueryTab) -> TableRows {
        guard tab.display.activeResultSet?.id == resultSet.id else { return resultSet.tableRows }
        return tabSessionRegistry.tableRows(for: tab.id)
    }
}
