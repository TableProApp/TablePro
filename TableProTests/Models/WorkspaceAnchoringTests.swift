import Foundation
@testable import TablePro
import Testing

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

    @Test("A database engine keys the container on the database")
    func databaseEngineUsesDatabase() {
        let container = WorkspaceAnchoring.containerName(
            of: tableTab(database: "app", schema: "public"),
            target: .database
        )
        #expect(container == "app")
    }

    @Test("A schema engine keys the container on the schema")
    func schemaEngineUsesSchema() {
        let container = WorkspaceAnchoring.containerName(
            of: tableTab(database: "app", schema: "reporting"),
            target: .schema
        )
        #expect(container == "reporting")
    }

    @Test("A schema engine names no container for a tab with no schema")
    func schemaEngineWithoutSchemaNamesNothing() {
        #expect(WorkspaceAnchoring.containerName(of: tableTab(database: "app"), target: .schema) == nil)
    }

    @Test("An engine that switches nothing names no container, so it gets a single workspace")
    func noSwitchTargetNamesNothing() {
        #expect(WorkspaceAnchoring.containerName(of: tableTab(database: "app"), target: nil) == nil)
        #expect(WorkspaceAnchoring.containers(in: [tableTab(database: "app")], target: nil).isEmpty)
    }

    /// A tab is reachable only through its entry, so an empty scratch tab names its container too.
    @Test("Containers collapse duplicates and include every tab that names one")
    func containersDeduplicateAndIncludeScratchTabs() {
        let tabs = [
            tableTab(database: "app"),
            tableTab(database: "app"),
            tableTab(database: "logs"),
            queryTab(database: "archive"),
        ]
        #expect(WorkspaceAnchoring.containers(in: tabs, target: .database) == ["app", "logs", "archive"])
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

    /// On an engine whose query tabs run against whatever schema is browsed, such a tab belongs to
    /// every entry rather than to one it cannot name.
    @Test("On a schema engine, a query tab with no schema names no container")
    func schemaEngineQueryTabWithoutSchemaNamesNothing() {
        let tab = queryTab("SELECT 1", database: "warehouse")
        #expect(WorkspaceAnchoring.containerName(of: tab, target: .schema) == nil)
        #expect(WorkspaceAnchoring.containerName(of: tab, target: .database) == "warehouse")
    }

    @Test("On a schema engine, a tab that names its schema is in that entry")
    func schemaEngineTabWithSchemaNamesIt() {
        let tab = queryTab("SELECT 1", database: "warehouse", schema: "reporting")
        #expect(WorkspaceAnchoring.containerName(of: tab, target: .schema) == "reporting")
    }

    @Test("A tab moving to another database changes the anchors, so the rail is told to reload")
    func rebindingChangesAnchors() {
        let before = WorkspaceAnchoring.anchors(in: [queryTab(database: "app")])
        let after = WorkspaceAnchoring.anchors(in: [queryTab(database: "logs")])
        #expect(before != after)
    }

    @Test("Typing into a query tab leaves the anchors alone")
    func typingKeepsAnchors() {
        let before = WorkspaceAnchoring.anchors(in: [queryTab()])
        let after = WorkspaceAnchoring.anchors(in: [queryTab("SELECT 1")])
        #expect(before == after)
    }

    @Test("A dropped database is listed under its own name only on an engine whose entries are databases")
    func entryNameFollowsTheEngineTarget() {
        let database = DatabaseContainerRef(kind: .database, database: "tenant_a", schema: nil, isSystem: false)
        let schema = DatabaseContainerRef(kind: .schema, database: "app", schema: "tenant_b", isSystem: false)
        #expect(WorkspaceAnchoring.entryName(of: database, target: .database) == "tenant_a")
        #expect(WorkspaceAnchoring.entryName(of: schema, target: .database) == nil)
        #expect(WorkspaceAnchoring.entryName(of: schema, target: .schema) == "tenant_b")
    }
}
