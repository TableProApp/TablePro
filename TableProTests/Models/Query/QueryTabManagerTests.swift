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
import Testing
@testable import TablePro

@Suite("QueryTabManager.selectedTabAndIndex")
@MainActor
struct QueryTabManagerSelectedTabAndIndexTests {
    @Test("returns nil when no tab is selected")
    func nilWhenNoSelection() {
        let manager = QueryTabManager()
        #expect(manager.selectedTabAndIndex == nil)
    }

    @Test("returns the selected tab and its index after addTableTab")
    func returnsSelectedTabAfterAdd() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users")

        let result = manager.selectedTabAndIndex
        #expect(result?.index == 0)
        #expect(result?.tab.tableContext.tableName == "users")
    }

    @Test("returns nil when selectedTabId points to a removed tab")
    func nilWhenSelectionIsStale() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users")
        let staleId = manager.tabs[0].id

        manager.tabs.removeAll()
        manager.selectedTabId = staleId

        #expect(manager.selectedTabAndIndex == nil)
    }

    @Test("returns the correct (tab, index) pair after switching tabs")
    func returnsCorrectPairAfterSwitch() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users")
        manager.addTableTab(tableName: "orders")
        let firstId = manager.tabs[0].id

        manager.selectedTabId = firstId

        let result = manager.selectedTabAndIndex
        #expect(result?.index == 0)
        #expect(result?.tab.tableContext.tableName == "users")
    }
}
