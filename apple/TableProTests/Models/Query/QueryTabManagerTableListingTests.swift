//
//  QueryTabManagerTableListingTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct QueryTabManagerTableListingTests {
    @Test("A listing tab is a read-only grid of its container, never an editor")
    func listingTabIsReadOnly() throws {
        let manager = QueryTabManager()

        let id = manager.addTableListingTab(title: "Tables: sales", databaseName: "shop", schemaName: "sales")

        let tab = try #require(manager.tabs.first)
        #expect(manager.tabs.count == 1)
        #expect(tab.id == id)
        #expect(manager.selectedTabId == id)
        #expect(tab.tabType == .tableListing)
        #expect(tab.title == "Tables: sales")
        #expect(tab.tableContext.databaseName == "shop")
        #expect(tab.tableContext.schemaName == "sales")
        #expect(tab.tableContext.isEditable == false)
        #expect(tab.content.query.isEmpty)
    }

    @Test("Asking again for the same container returns to its tab")
    func sameContainerReusesTheTab() {
        let manager = QueryTabManager()
        let first = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "sales")
        manager.addTab(initialQuery: "SELECT 1", databaseName: "shop")

        let second = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "sales")

        #expect(second == first)
        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTabId == first)
    }

    @Test("Another schema or database gets a listing of its own")
    func otherContainersGetTheirOwnTab() {
        let manager = QueryTabManager()
        let sales = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "sales")
        let hr = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "hr")
        let other = manager.addTableListingTab(title: "Tables", databaseName: "archive", schemaName: "sales")
        let unscoped = manager.addTableListingTab(title: "Tables", databaseName: "shop", schemaName: "")

        #expect(Set([sales, hr, other, unscoped]).count == 4)
        #expect(manager.tabs.first { $0.id == unscoped }?.tableContext.schemaName == nil)
    }

    @Test("The title names the schema only where tables are listed per schema")
    func titleNamesTheSchema() {
        #expect(QueryTabManager.tableListingTitle(kindTitle: "Tables", schemaName: "public") == "Tables: public")
        #expect(QueryTabManager.tableListingTitle(kindTitle: "Collections", schemaName: nil) == "Collections")
        #expect(QueryTabManager.tableListingTitle(kindTitle: "Tables", schemaName: "") == "Tables")
    }
}
