//
//  TableTabDuplicationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Table tab duplication")
@MainActor
struct TableTabDuplicationTests {
    /// The default. Clicking a table that is already open switches to it rather than piling up
    /// copies of the same browse.
    @Test("A second open of the same table reselects the existing tab")
    func secondOpenReselects() throws {
        let manager = QueryTabManager()
        let created = try manager.addTableTab(tableName: "orders", databaseName: "shop")
        let firstId = try #require(manager.selectedTabId)

        let createdAgain = try manager.addTableTab(tableName: "orders", databaseName: "shop")

        #expect(created)
        #expect(createdAgain == false)
        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabId == firstId)
    }

    /// "Open in New Tab" means what it says only if the intent survives this far down. It used to
    /// be discarded here, so the menu item silently reselected the tab that was already open.
    @Test("allowsDuplicate gives a table that is already open a second tab")
    func allowsDuplicateAppendsASecondTab() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "orders", databaseName: "shop")
        let firstId = try #require(manager.selectedTabId)

        let created = try manager.addTableTab(
            tableName: "orders", databaseName: "shop", allowsDuplicate: true
        )
        let secondId = try #require(manager.selectedTabId)

        #expect(created)
        #expect(manager.tabs.count == 2)
        #expect(secondId != firstId)
        #expect(manager.tabs.allSatisfy { $0.tableContext.tableName == "orders" })
    }

    @Test("A duplicated tab carries the same browse context and its own state")
    func duplicatedTabCarriesItsOwnState() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "orders", databaseName: "shop", schemaName: "sales")
        try manager.addTableTab(
            tableName: "orders", databaseName: "shop", schemaName: "sales", allowsDuplicate: true
        )

        let first = try #require(manager.tabs.first)
        let second = try #require(manager.tabs.last)

        #expect(first.tableContext.databaseName == second.tableContext.databaseName)
        #expect(first.tableContext.schemaName == second.tableContext.schemaName)
        #expect(first.content.query == second.content.query)
        #expect(first.filterState == TabFilterState())
        #expect(second.filterState == TabFilterState())
    }

    @Test("The tab showing a table is the selected one when a table has two")
    func tabShowingTablePrefersTheSelectedTab() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "orders", databaseName: "shop")
        let firstId = try #require(manager.selectedTabId)
        try manager.addTableTab(tableName: "orders", databaseName: "shop", allowsDuplicate: true)
        let secondId = try #require(manager.selectedTabId)

        #expect(
            manager.tabShowingTable(named: "orders", databaseName: "shop", schemaName: nil)?.id
                == secondId
        )

        manager.selectedTabId = firstId
        #expect(
            manager.tabShowingTable(named: "orders", databaseName: "shop", schemaName: nil)?.id
                == firstId
        )
    }

    @Test("A table with no tab has none showing it")
    func tabShowingTableIsNilWithoutAMatch() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "orders", databaseName: "shop")

        #expect(manager.tabShowingTable(named: "customers", databaseName: "shop", schemaName: nil) == nil)
        #expect(manager.tabShowingTable(named: "orders", databaseName: "other", schemaName: nil) == nil)
    }
}
