//
//  SidebarObjectSelectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SidebarObjectSelection")
struct SidebarObjectSelectionTests {
    private let connectionId = UUID()

    private func scope(_ database: String, schema: String? = nil) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    private var tables: [TableInfo] {
        [
            TestFixtures.makeTableInfo(name: "role_ability"),
            TestFixtures.makeTableInfo(name: "orders"),
        ]
    }

    private func table(_ name: String, schema: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    @Test("The tab's table is marked when the tab is in the container being browsed")
    func marksTabInBrowsedContainer() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: scope("banshi_online"),
            browseScope: scope("banshi_online"),
            tables: tables
        )
        #expect(selection == .mark([TestFixtures.makeTableInfo(name: "orders")]))
    }

    @Test("A tab in another database marks nothing, so the same-named row stays clickable")
    func marksNothingForTabInAnotherDatabase() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "role_ability",
            tabScope: scope("banshi_test"),
            browseScope: scope("banshi_online"),
            tables: tables
        )
        #expect(selection == .mark([]))
    }

    @Test("A tab in another schema of the same database keeps its mark, because its row is listed")
    func marksTabInAnotherSchemaOfTheSameDatabase() {
        let publicOrders = table("orders", schema: "public")
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: scope("app", schema: "public"),
            browseScope: scope("app", schema: "reporting"),
            tables: [publicOrders, table("orders", schema: "reporting")]
        )
        #expect(selection == .mark([publicOrders]))
    }

    @Test("Two rows sharing a name in one database are told apart by the tab's schema")
    func picksTheRowInTheTabsSchema() {
        let reportingOrders = table("orders", schema: "reporting")
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: scope("app", schema: "reporting"),
            browseScope: scope("app", schema: "reporting"),
            tables: [table("orders", schema: "public"), reportingOrders]
        )
        #expect(selection == .mark([reportingOrders]))
    }

    @Test("A tab naming no schema takes the first row with that name, as before")
    func fallsBackToTheNameWhenTheTabNamesNoSchema() {
        let first = table("orders", schema: "public")
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: scope("app"),
            browseScope: scope("app"),
            tables: [first, table("orders", schema: "reporting")]
        )
        #expect(selection == .mark([first]))
    }

    @Test("A tab that names no table marks nothing")
    func marksNothingForQueryTab() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: nil,
            tabScope: scope("banshi_online"),
            browseScope: scope("banshi_online"),
            tables: tables
        )
        #expect(selection == .mark([]))
    }

    @Test("A table the browsed container does not list marks nothing")
    func marksNothingWhenTableIsAbsent() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "audit_log",
            tabScope: scope("banshi_online"),
            browseScope: scope("banshi_online"),
            tables: tables
        )
        #expect(selection == .mark([]))
    }

    @Test("Nothing is re-asserted while the object list has not loaded")
    func leavesMarkAloneBeforeTablesLoad() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: scope("banshi_online"),
            browseScope: scope("banshi_online"),
            tables: []
        )
        #expect(selection == .leaveUnchanged)
    }

    @Test("A tab with no scope of its own marks nothing rather than guessing")
    func marksNothingWithoutAScope() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: nil,
            browseScope: scope("banshi_online"),
            tables: tables
        )
        #expect(selection == .mark([]))
    }
}
