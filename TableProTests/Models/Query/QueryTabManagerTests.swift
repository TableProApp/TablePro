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
import TableProPluginKit
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

    @Test("uses injected default page size for new table tabs")
    func usesInjectedDefaultPageSizeForTableTabs() throws {
        let manager = QueryTabManager(defaultPageSizeProvider: { 42 })

        try manager.addTableTab(tableName: "users")

        #expect(manager.tabs[0].pagination.pageSize == 42)
        #expect(manager.tabs[0].content.query.contains("42"))
    }

    @Test("uses injected default page size when replacing tab content")
    func usesInjectedDefaultPageSizeWhenReplacingTabContent() throws {
        let manager = QueryTabManager(defaultPageSizeProvider: { 75 })
        manager.addTab()

        let replaced = try manager.replaceTabContent(tableName: "users")

        #expect(replaced)
        #expect(manager.tabs[0].pagination.pageSize == 75)
        #expect(manager.tabs[0].content.query.contains("75"))
    }
}
