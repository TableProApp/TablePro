//
//  EditorTabLabelResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Editor tab labels")
@MainActor
struct EditorTabLabelResolverTests {
    private func tableTab(_ name: String, database: String = "", schema: String? = nil) -> QueryTab {
        var tab = QueryTab(title: name, tabType: .table, tableName: name)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("A title no other tab uses stays bare")
    func leavesUniqueTitlesAlone() {
        let tabs = [tableTab("orders", database: "app"), tableTab("customers", database: "logs")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[1].id]?.text == "customers")
    }

    @Test("The same table open in two databases is qualified on both tabs")
    func qualifiesACollisionAcrossDatabases() {
        let tabs = [
            tableTab("role_ability", database: "banshi_test"),
            tableTab("role_ability", database: "banshi_online"),
        ]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "banshi_test.role_ability")
        #expect(labels[tabs[1].id]?.text == "banshi_online.role_ability")
    }

    @Test("Two tabs sharing a title inside one database stay bare, because naming it tells them apart")
    func leavesACollisionInsideOneContainerAlone() {
        let tabs = [tableTab("orders", database: "app"), tableTab("orders", database: "app")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[1].id]?.text == "orders")
    }

    @Test("The description names the container even when the label did not need it")
    func describesTheContainerRegardless() {
        let tabs = [tableTab("orders", database: "app")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[0].id]?.description == "app.orders")
    }

    @Test("A tab that names no container is described by its title alone")
    func describesAContainerlessTabByItsTitle() {
        let tabs = [tableTab("orders")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: nil)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[0].id]?.description == "orders")
    }

    @Test("A title already carrying its schema is not qualified twice")
    func doesNotQualifyTwice() {
        var reporting = tableTab("orders", database: "app", schema: "reporting")
        reporting.title = "reporting.orders"
        let tabs = [reporting, tableTab("orders", database: "app", schema: "public")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .schema)

        #expect(labels[tabs[0].id]?.description == "reporting.orders")
    }

    @Test("A tab that names no object is never qualified, whatever database it was opened from")
    func neverQualifiesANonObjectTab() {
        var dashboard = QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
        dashboard.tableContext.databaseName = "app"
        var other = QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
        other.tableContext.databaseName = "staging"
        let labels = EditorTabLabelResolver.resolve(tabs: [dashboard, other], target: .database)

        #expect(labels[dashboard.id]?.text == "Server Dashboard")
        #expect(labels[dashboard.id]?.description == "Server Dashboard")
        #expect(labels[other.id]?.text == "Server Dashboard")
    }

    @Test("A collision between a bound and an unbound tab qualifies only the one that can be")
    func qualifiesOnlyTheTabWithAContainer() {
        let tabs = [tableTab("orders", database: "app"), tableTab("orders")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "app.orders")
        #expect(labels[tabs[1].id]?.text == "orders")
    }
}
