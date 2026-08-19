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

    @Test("A tab in another schema of the same database marks nothing")
    func marksNothingForTabInAnotherSchema() {
        let selection = SidebarObjectSelection.resolve(
            tabTableName: "orders",
            tabScope: scope("app", schema: "public"),
            browseScope: scope("app", schema: "reporting"),
            tables: tables
        )
        #expect(selection == .mark([]))
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
