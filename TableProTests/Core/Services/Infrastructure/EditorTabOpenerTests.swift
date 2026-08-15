import Foundation
@testable import TablePro
import Testing

@Suite("Editor tab opener")
@MainActor
struct EditorTabOpenerTests {
    private func makeConnection() -> DatabaseConnection {
        DatabaseConnection(name: "Opener", type: .mysql)
    }

    private func tablePayload(_ connectionId: UUID, table: String) -> EditorTabPayload {
        EditorTabPayload(
            connectionId: connectionId,
            tabType: .table,
            tableName: table,
            databaseName: "shop",
            isView: false
        )
    }

    /// The regression this guards: a payload naming a table used to open a tab only while a
    /// connection was being created for it, so asking a connection that was already open for a
    /// second table did nothing at all.
    @Test("A table payload opens a tab in a list that already has one")
    func tableOpensIntoPopulatedList() {
        let connection = makeConnection()
        let manager = QueryTabManager()
        manager.addTab(title: "Query 1")

        EditorTabOpener.apply(
            tablePayload(connection.id, table: "orders"),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTab?.tableContext.tableName == "orders")
    }

    @Test("Two different tables open two tabs")
    func twoTablesOpenTwoTabs() {
        let connection = makeConnection()
        let manager = QueryTabManager()

        EditorTabOpener.apply(
            tablePayload(connection.id, table: "orders"),
            to: manager,
            connection: connection,
            toolbarState: nil
        )
        EditorTabOpener.apply(
            tablePayload(connection.id, table: "customers"),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTab?.tableContext.tableName == "customers")
    }

    @Test("A new empty tab payload adds a query tab")
    func newEmptyTabAddsQueryTab() {
        let connection = makeConnection()
        let manager = QueryTabManager()

        EditorTabOpener.apply(
            EditorTabPayload(connectionId: connection.id, intent: .newEmptyTab),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTab?.tabType == .query)
    }

    /// Restoring a session brings its own tabs back, so the payload must not add one on top.
    @Test("A restore payload opens nothing")
    func restoreOpensNothing() {
        let connection = makeConnection()
        let manager = QueryTabManager()

        EditorTabOpener.apply(
            EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.isEmpty)
    }

    @Test("A query payload with no content opens nothing")
    func emptyQueryPayloadOpensNothing() {
        let connection = makeConnection()
        let manager = QueryTabManager()

        EditorTabOpener.apply(
            EditorTabPayload(connectionId: connection.id, tabType: .query),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.isEmpty)
    }

    @Test("A query payload carrying a query opens a tab holding it")
    func queryPayloadOpensTab() {
        let connection = makeConnection()
        let manager = QueryTabManager()

        EditorTabOpener.apply(
            EditorTabPayload(
                connectionId: connection.id,
                tabType: .query,
                initialQuery: "SELECT 1"
            ),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTab?.content.query == "SELECT 1")
    }
}
