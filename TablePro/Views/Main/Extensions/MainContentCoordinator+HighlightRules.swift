//
//  MainContentCoordinator+HighlightRules.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func highlightRuleScope(for tab: QueryTab) -> TableScope? {
        tab.tableContext.scope(connectionId: connectionId)
    }

    func highlightRules(for tab: QueryTab) -> [HighlightRule] {
        guard let scope = highlightRuleScope(for: tab) else { return tab.sessionHighlightRules }
        return HighlightRuleStorage.shared.rules(for: scope)
    }

    func setHighlightRules(_ rules: [HighlightRule], forTab tabId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if let scope = highlightRuleScope(for: tabManager.tabs[index]) {
            HighlightRuleStorage.shared.setRules(rules, for: scope)
            return
        }
        guard tabManager.tabs[index].sessionHighlightRules != rules else { return }
        tabManager.mutate(at: index) { $0.sessionHighlightRules = rules }
    }

    /// Only a rule this result does not already carry earns the first position. The order is the
    /// user's, and the popover promises the first match sets the color, so promoting a rule the user
    /// is merely recoloring hands it rows another rule was coloring. `paletteItem` passes back the
    /// rule it found for the cell, so the id names it; the condition arm covers a rule whose id was
    /// regenerated on load, and both arms resolve to the same rule because that is the one the menu
    /// showed.
    func applyQuickHighlight(_ rule: HighlightRule, forTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        var rules = highlightRules(for: tab)
        if let index = rules.firstIndex(where: { $0.id == rule.id || $0.hasSameCondition(as: rule) }) {
            rules[index] = rule
        } else {
            rules.insert(rule, at: 0)
        }
        setHighlightRules(rules, forTab: tabId)
    }

    func removeHighlightRules(sharingConditionWith rule: HighlightRule, forTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        let rules = highlightRules(for: tab).filter { !$0.hasSameCondition(as: rule) }
        setHighlightRules(rules, forTab: tabId)
    }

    func discardIncompleteHighlightRules(forTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        let rules = highlightRules(for: tab)
        let complete = rules.filter(\.isValid)
        guard complete.count != rules.count else { return }
        setHighlightRules(complete, forTab: tabId)
    }

    func presentHighlightRules(addingRuleForColumn columnName: String? = nil, occurrence: Int = 0) {
        guard let index = tabManager.selectedTabIndex else { return }
        let tabId = tabManager.tabs[index].id
        if let columnName {
            let newRule = HighlightRule(columnName: columnName, columnOccurrence: occurrence)
            setHighlightRules(highlightRules(for: tabManager.tabs[index]) + [newRule], forTab: tabId)
        }
        tabManager.mutate(at: index) { $0.display.highlightRulesPresentationRequest &+= 1 }
    }

    var canPresentHighlightRules: Bool {
        guard hasMountedDataGrid,
              let tab = tabManager.selectedTab,
              tab.display.resultsViewMode == .data else { return false }
        return !(tabSessionRegistry.existingTableRows(for: tab.id)?.columns.isEmpty ?? true)
    }
}
