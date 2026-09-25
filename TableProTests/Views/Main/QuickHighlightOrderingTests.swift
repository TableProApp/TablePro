//
//  QuickHighlightOrderingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct QuickHighlightOrderingTests {
    private func makeCoordinator() -> (MainContentCoordinator, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let tab = QueryTab(title: "Q1", query: "SELECT status, country FROM orders", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tab.id)
    }

    private func rule(
        _ columnName: String,
        _ value: String,
        color: HighlightColor = .yellow,
        isEnabled: Bool = true,
        target: HighlightTarget = .row
    ) -> HighlightRule {
        HighlightRule(
            isEnabled: isEnabled,
            columnName: columnName,
            value: value,
            color: color,
            target: target
        )
    }

    @Test("Recoloring a rule leaves it where the user put it")
    func recoloringKeepsPosition() {
        let (coordinator, tabId) = makeCoordinator()
        let shipped = rule("status", "shipped", color: .green)
        let american = rule("country", "US", color: .red)
        coordinator.setHighlightRules([shipped, american], forTab: tabId)

        var recolored = american
        recolored.color = .blue
        coordinator.applyQuickHighlight(recolored, forTab: tabId)

        let rules = coordinator.highlightRules(for: coordinator.tabManager.tabs[0])
        #expect(rules.map(\.id) == [shipped.id, american.id])
        #expect(rules[1].color == .blue)
    }

    @Test("Recoloring a rule does not take rows the rule above it was coloring")
    func recoloringDoesNotStealRows() {
        let (coordinator, tabId) = makeCoordinator()
        let shipped = rule("status", "shipped", color: .green)
        let american = rule("country", "US", color: .red)
        coordinator.setHighlightRules([shipped, american], forTab: tabId)

        var recolored = american
        recolored.color = .blue
        coordinator.applyQuickHighlight(recolored, forTab: tabId)

        let set = HighlightRuleSet(
            rules: coordinator.highlightRules(for: coordinator.tabManager.tabs[0]),
            columns: ["status", "country"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        let highlight = set.highlight(for: ContiguousArray([PluginCellValue.text("shipped"), .text("US")]))
        #expect(highlight.rowColor == .green)
    }

    @Test("A rule this result has never carried still goes in first")
    func aNewRuleGoesFirst() {
        let (coordinator, tabId) = makeCoordinator()
        let existing = rule("status", "shipped", color: .green)
        coordinator.setHighlightRules([existing], forTab: tabId)

        let fresh = rule("country", "US", color: .blue)
        coordinator.applyQuickHighlight(fresh, forTab: tabId)

        let rules = coordinator.highlightRules(for: coordinator.tabManager.tabs[0])
        #expect(rules.map(\.id) == [fresh.id, existing.id])
    }

    @Test("A quick rule matching a saved condition replaces it where it stands")
    func aMatchingConditionReplacesInPlace() {
        let (coordinator, tabId) = makeCoordinator()
        let american = rule("country", "US", color: .red)
        let shipped = rule("status", "shipped", color: .green)
        coordinator.setHighlightRules([american, shipped], forTab: tabId)

        let reissued = rule("status", "shipped", color: .blue)
        coordinator.applyQuickHighlight(reissued, forTab: tabId)

        let rules = coordinator.highlightRules(for: coordinator.tabManager.tabs[0])
        #expect(rules.count == 2)
        #expect(rules[1].color == .blue)
        #expect(rules[0].id == american.id)
    }

    @Test("Recoloring no longer deletes the other rules sharing the condition")
    func duplicatesSurviveARecolor() {
        let (coordinator, tabId) = makeCoordinator()
        let red = rule("status", "failed", color: .red)
        let orange = rule("status", "failed", color: .orange)
        coordinator.setHighlightRules([red, orange], forTab: tabId)

        var purple = red
        purple.color = .purple
        coordinator.applyQuickHighlight(purple, forTab: tabId)

        let rules = coordinator.highlightRules(for: coordinator.tabManager.tabs[0])
        #expect(rules.count == 2)
        #expect(rules.map(\.color) == [.purple, .orange])
    }

    @Test("Picking a color turns a switched-off rule back on without moving it")
    func recoloringReenablesInPlace() {
        let (coordinator, tabId) = makeCoordinator()
        let first = rule("status", "shipped", color: .green)
        let off = rule("country", "US", color: .red, isEnabled: false)
        coordinator.setHighlightRules([first, off], forTab: tabId)

        var revived = off
        revived.color = .blue
        revived.isEnabled = true
        coordinator.applyQuickHighlight(revived, forTab: tabId)

        let rules = coordinator.highlightRules(for: coordinator.tabManager.tabs[0])
        #expect(rules.map(\.id) == [first.id, off.id])
        #expect(rules[1].isEnabled)
        #expect(rules[1].color == .blue)
    }

    /// Apply edits one rule, Remove Highlight takes the value's color away, so it stays
    /// condition-scoped: leaving a duplicate behind would leave the value still colored.
    @Test("Remove Highlight still takes every rule sharing the condition")
    func removeTakesEveryDuplicate() {
        let (coordinator, tabId) = makeCoordinator()
        let red = rule("status", "failed", color: .red)
        let other = rule("country", "US", color: .blue)
        let green = rule("status", "failed", color: .green)
        coordinator.setHighlightRules([red, other, green], forTab: tabId)

        coordinator.removeHighlightRules(sharingConditionWith: red, forTab: tabId)

        let rules = coordinator.highlightRules(for: coordinator.tabManager.tabs[0])
        #expect(rules.map(\.id) == [other.id])
    }

    @Test("A switched-off rule is not offered as the color the cell is painted")
    func markedColorIgnoresADisabledRule() {
        let enabled = rule("country", "US", color: .blue)
        let disabled = rule("country", "US", color: .blue, isEnabled: false)

        #expect(HighlightMenuBuilder.markedColor(for: nil) == nil)
        #expect(HighlightMenuBuilder.markedColor(for: disabled) == nil)
        #expect(HighlightMenuBuilder.markedColor(for: enabled) == .blue)
    }
}
