import Foundation
@testable import TablePro
import Testing

@Suite("Workspace anchoring")
@MainActor
struct WorkspaceAnchoringTests {
    private func queryTab(
        _ query: String = "",
        database: String = "app",
        schema: String? = nil
    ) -> QueryTab {
        var tab = QueryTab(title: "Query 1", query: query)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    private func tableTab(database: String = "app", schema: String? = nil) -> QueryTab {
        var tab = QueryTab(title: "orders", tabType: .table, tableName: "orders")
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("A brand new query tab is not work, so it holds nothing")
    func emptyQueryTabHoldsNothing() {
        #expect(!WorkspaceAnchoring.hasWork(queryTab()))
    }

    @Test("A query tab with text holds its database")
    func typedQueryTabHoldsItsContainer() {
        #expect(WorkspaceAnchoring.hasWork(queryTab("SELECT 1")))
    }

    @Test("A query tab the user has edited rows in holds its database even with no text")
    func interactedQueryTabHoldsItsContainer() {
        var tab = queryTab()
        tab.hasUserInteraction = true
        #expect(WorkspaceAnchoring.hasWork(tab))
    }

    @Test("A file-backed query tab holds its database even before anything is typed")
    func fileBackedQueryTabHoldsItsContainer() {
        var tab = queryTab()
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/report.sql")
        #expect(WorkspaceAnchoring.hasWork(tab))
    }

    @Test("Every tab that is not a query tab holds its database")
    func nonQueryTabsAlwaysHold() {
        #expect(WorkspaceAnchoring.hasWork(tableTab()))
    }

    @Test("A database engine keys the container on the database")
    func databaseEngineUsesDatabase() {
        let container = WorkspaceAnchoring.container(
            of: tableTab(database: "app", schema: "public"),
            target: .database
        )
        #expect(container == "app")
    }

    @Test("A schema engine keys the container on the schema")
    func schemaEngineUsesSchema() {
        let container = WorkspaceAnchoring.container(
            of: tableTab(database: "app", schema: "reporting"),
            target: .schema
        )
        #expect(container == "reporting")
    }

    @Test("A schema engine names no container for a tab with no schema")
    func schemaEngineWithoutSchemaNamesNothing() {
        #expect(WorkspaceAnchoring.container(of: tableTab(database: "app"), target: .schema) == nil)
    }

    @Test("An engine that switches nothing names no container, so it gets a single workspace")
    func noSwitchTargetNamesNothing() {
        #expect(WorkspaceAnchoring.container(of: tableTab(database: "app"), target: nil) == nil)
        #expect(WorkspaceAnchoring.containers(in: [tableTab(database: "app")], target: nil).isEmpty)
    }

    @Test("Containers collapse duplicates and skip tabs that hold nothing")
    func containersDeduplicateAndSkipScratchTabs() {
        let tabs = [
            tableTab(database: "app"),
            tableTab(database: "app"),
            tableTab(database: "logs"),
            queryTab(database: "archive"),
        ]
        #expect(WorkspaceAnchoring.containers(in: tabs, target: .database) == ["app", "logs"])
    }

    @Test("The browsed container falls back to the connection's database when none is set")
    func browsedContainerFallsBackToConnectionDatabase() {
        let connection = TestFixtures.makeConnection(database: "app")
        let session = ConnectionSession(connection: connection)
        #expect(WorkspaceAnchoring.browsedContainer(of: session, target: .database) == "app")
    }

    @Test("A saved connection names no container for a schema engine")
    func defaultContainerIsAbsentForSchemaEngines() {
        let connection = TestFixtures.makeConnection(database: "app")
        #expect(WorkspaceAnchoring.defaultContainer(of: connection, target: .schema) == nil)
        #expect(WorkspaceAnchoring.defaultContainer(of: connection, target: .database) == "app")
    }

    @Test("On a schema engine, a query tab with no schema holds nothing rather than a container it cannot name")
    func schemaEngineQueryTabWithoutSchemaHoldsNothing() {
        var tab = queryTab("SELECT 1", database: "warehouse")
        tab.hasUserInteraction = true
        #expect(WorkspaceAnchoring.hasWork(tab))
        #expect(!WorkspaceAnchoring.holdsContainer(tab, target: .schema))
        #expect(WorkspaceAnchoring.holdsContainer(tab, target: .database))
    }

    @Test("On a schema engine, a tab that names its schema still holds it")
    func schemaEngineTabWithSchemaHolds() {
        let tab = queryTab("SELECT 1", database: "warehouse", schema: "reporting")
        #expect(WorkspaceAnchoring.holdsContainer(tab, target: .schema))
        #expect(WorkspaceAnchoring.container(of: tab, target: .schema) == "reporting")
    }

    @Test("Typing into a query tab changes the anchors, so the rail is told to reload")
    func typingChangesAnchors() {
        let before = WorkspaceAnchoring.anchors(in: [queryTab()])
        let after = WorkspaceAnchoring.anchors(in: [queryTab("SELECT 1")])
        #expect(before != after)
    }

    @Test("Editing a query that already had text leaves the anchors alone")
    func editingTypedQueryKeepsAnchors() {
        let before = WorkspaceAnchoring.anchors(in: [queryTab("SELECT 1")])
        let after = WorkspaceAnchoring.anchors(in: [queryTab("SELECT 2")])
        #expect(before == after)
    }
}
