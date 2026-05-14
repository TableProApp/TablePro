//
//  QueryTabManagerTests.swift
//  TableProTests
//
//  Locks the contract for selectedTabAndIndex — the helper that
//  MainContentCoordinator+Pagination (and future coordinator extensions)
//  use in place of the selectedTabIndex + bounds-check + tabs[index]
//  pattern. The tests guard against silent staleness if selectedTabId
//  ever points to a removed tab.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("QueryTabManager.selectedTabAndIndex")
@MainActor
struct QueryTabManagerSelectedTabAndIndexTests {
    @Test("returns nil when no tab is selected")
    func nilWhenNoSelection() {
        let manager = QueryTabManager()
        #expect(manager.selectedTabAndIndex == nil)
    }

    @Test("returns the selected tab and its index after addTableTab")
    func returnsSelectedTabAfterAdd() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")

        let result = manager.selectedTabAndIndex
        #expect(result?.index == 0)
        #expect(result?.tab.tableContext.tableName == "users")
    }

    @Test("returns nil when selectedTabId points to a removed tab")
    func nilWhenSelectionIsStale() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        let staleId = manager.tabs[0].id

        manager.tabs.removeAll()
        manager.selectedTabId = staleId

        #expect(manager.selectedTabAndIndex == nil)
    }

    @Test("returns the correct (tab, index) pair after switching tabs")
    func returnsCorrectPairAfterSwitch() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        try manager.addTableTab(tableName: "orders")
        let firstId = manager.tabs[0].id

        manager.selectedTabId = firstId

        let result = manager.selectedTabAndIndex
        #expect(result?.index == 0)
        #expect(result?.tab.tableContext.tableName == "users")
    }
}

@Suite("QueryTabManager.removeTab")
@MainActor
struct QueryTabManagerRemoveTabTests {
    @Test("removing an unknown id is a no-op")
    func removeUnknownIdIsNoOp() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        let id = manager.tabs[0].id

        manager.removeTab(id: UUID())

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabId == id)
    }

    @Test("removing a non-selected tab keeps the selection")
    func removeNonSelectedKeepsSelection() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        manager.addTab(title: "Query 2")
        let firstId = manager.tabs[0].id
        let secondId = manager.tabs[1].id
        manager.selectedTabId = secondId

        manager.removeTab(id: firstId)

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabId == secondId)
    }

    @Test("removing the selected tab selects the tab at the same index")
    func removeSelectedSelectsSameIndex() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        manager.addTab(title: "Query 2")
        manager.addTab(title: "Query 3")
        let secondId = manager.tabs[1].id
        let thirdId = manager.tabs[2].id
        manager.selectedTabId = secondId

        manager.removeTab(id: secondId)

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTabId == thirdId)
    }

    @Test("removing the selected last tab selects the new last tab")
    func removeSelectedLastSelectsNewLast() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        manager.addTab(title: "Query 2")
        let firstId = manager.tabs[0].id
        let secondId = manager.tabs[1].id
        manager.selectedTabId = secondId

        manager.removeTab(id: secondId)

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabId == firstId)
    }

    @Test("removing the only tab clears the selection")
    func removeOnlyTabClearsSelection() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        let id = manager.tabs[0].id

        manager.removeTab(id: id)

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedTabId == nil)
    }
}

@Suite("QueryTabManager.selectTab")
@MainActor
struct QueryTabManagerSelectTabTests {
    @Test("selecting a known id updates the selection")
    func selectKnownIdUpdatesSelection() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        manager.addTab(title: "Query 2")
        let firstId = manager.tabs[0].id

        manager.selectTab(id: firstId)

        #expect(manager.selectedTabId == firstId)
    }

    @Test("selecting an unknown id is a no-op")
    func selectUnknownIdIsNoOp() {
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")
        let id = manager.tabs[0].id

        manager.selectTab(id: UUID())

        #expect(manager.selectedTabId == id)
    }
}

@Suite("QueryTabManager.moveTab")
@MainActor
struct QueryTabManagerMoveTabTests {
    private func makeManager(titles: [String]) -> QueryTabManager {
        let manager = QueryTabManager()
        for title in titles {
            manager.addTab(title: title)
        }
        return manager
    }

    @Test("moving a tab forward reorders the list")
    func moveForwardReorders() {
        let manager = makeManager(titles: ["A", "B", "C"])

        manager.moveTab(from: IndexSet(integer: 0), to: 3)

        #expect(manager.tabs.map(\.title) == ["B", "C", "A"])
    }

    @Test("moving a tab backward reorders the list")
    func moveBackwardReorders() {
        let manager = makeManager(titles: ["A", "B", "C"])

        manager.moveTab(from: IndexSet(integer: 2), to: 0)

        #expect(manager.tabs.map(\.title) == ["C", "A", "B"])
    }

    @Test("moving a tab to its current position is a no-op")
    func moveToSamePositionIsNoOp() {
        let manager = makeManager(titles: ["A", "B", "C"])

        manager.moveTab(from: IndexSet(integer: 1), to: 1)

        #expect(manager.tabs.map(\.title) == ["A", "B", "C"])
    }

    @Test("moving preserves the selected tab id")
    func movePreservesSelection() {
        let manager = makeManager(titles: ["A", "B", "C"])
        let bId = manager.tabs[1].id
        manager.selectedTabId = bId

        manager.moveTab(from: IndexSet(integer: 0), to: 3)

        #expect(manager.selectedTabId == bId)
        #expect(manager.tabs.map(\.title) == ["B", "C", "A"])
    }
}
