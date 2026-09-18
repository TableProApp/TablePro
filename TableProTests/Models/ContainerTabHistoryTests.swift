//
//  ContainerTabHistoryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Container tab history")
@MainActor
struct ContainerTabHistoryTests {
    private func tableTab(_ name: String, database: String, schema: String? = nil) -> QueryTab {
        var tab = QueryTab(title: name, tabType: .table, tableName: name)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("With no history, a container lands on its last tab in strip order")
    func fallsBackToLastTabInContainer() {
        let first = tableTab("orders", database: "app")
        let second = tableTab("customers", database: "app")
        let other = tableTab("orders", database: "logs")
        let history = ContainerTabHistory()

        #expect(
            history.tabToSelect(inContainer: "app", among: [first, second, other], target: .database)
                == second.id
        )
    }

    @Test("A container lands on the tab it was last on")
    func returnsTheRememberedTab() {
        let first = tableTab("orders", database: "app")
        let second = tableTab("customers", database: "app")
        var history = ContainerTabHistory()
        history.record(tabId: first.id, container: "app")

        #expect(history.tabToSelect(inContainer: "app", among: [first, second], target: .database) == first.id)
    }

    @Test("A remembered tab that has closed falls back instead of landing on nothing")
    func fallsBackWhenRememberedTabIsGone() {
        let closed = tableTab("orders", database: "app")
        let survivor = tableTab("customers", database: "app")
        var history = ContainerTabHistory()
        history.record(tabId: closed.id, container: "app")

        #expect(history.tabToSelect(inContainer: "app", among: [survivor], target: .database) == survivor.id)
    }

    @Test("A remembered tab rebound to another database no longer answers for the old one")
    func fallsBackWhenRememberedTabMovedContainer() {
        var moved = tableTab("orders", database: "app")
        let stayed = tableTab("customers", database: "app")
        var history = ContainerTabHistory()
        history.record(tabId: moved.id, container: "app")
        moved.tableContext.databaseName = "logs"

        #expect(history.tabToSelect(inContainer: "app", among: [moved, stayed], target: .database) == stayed.id)
    }

    @Test("A container holding no tab selects nothing")
    func selectsNothingForATablessContainer() {
        let history = ContainerTabHistory()
        #expect(
            history.tabToSelect(
                inContainer: "logs",
                among: [tableTab("orders", database: "app")],
                target: .database
            ) == nil
        )
    }

    @Test("On a schema-switching engine the container is the schema")
    func keysOnSchemaWhenThatIsTheContainer() {
        let publicTab = tableTab("orders", database: "app", schema: "public")
        let reportingTab = tableTab("orders", database: "app", schema: "reporting")
        let history = ContainerTabHistory()

        #expect(
            history.tabToSelect(inContainer: "reporting", among: [publicTab, reportingTab], target: .schema)
                == reportingTab.id
        )
    }

    @Test("A tab that names no container is recorded under none")
    func recordsNothingForAnUnnamedContainer() {
        let tab = tableTab("orders", database: "app")
        var history = ContainerTabHistory()
        history.record(tabId: tab.id, container: nil)
        history.record(tabId: tab.id, container: "")

        #expect(history == ContainerTabHistory())
    }
}
