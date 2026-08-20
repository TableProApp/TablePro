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

    /// The FK arrow's "Open in New Tab" builds a payload carrying its own filter. It used to be
    /// written onto whatever tab the table already had, destroying filters the user applied there
    /// and leaving the grid on rows the new filter never ran against.
    @Test("A payload that must open its own tab does not write over the tab already showing the table")
    func forcesNewTabLeavesTheExistingTabAlone() throws {
        let connection = makeConnection()
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "customers", databaseType: .mysql, databaseName: "shop")
        let existingId = try #require(manager.selectedTabId)
        let userFilter = TabFilterState(
            filters: [TableFilter(columnName: "country", filterOperator: .equal, value: "DE")],
            commit: .all,
            isVisible: true,
            filterLogicMode: .and
        )
        manager.mutate(at: 0) { $0.filterState = userFilter }

        let fkFilter = TabFilterState(
            filters: [TableFilter(columnName: "id", filterOperator: .equal, value: "42")],
            commit: .all,
            isVisible: true,
            filterLogicMode: .and
        )
        EditorTabOpener.apply(
            EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: "customers",
                databaseName: "shop",
                isView: false,
                forcesNewTab: true,
                initialFilterState: fkFilter
            ),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.count == 2)
        #expect(manager.tabs[0].id == existingId)
        #expect(manager.tabs[0].filterState == userFilter)
        #expect(manager.tabs[1].filterState == fkFilter)
        #expect(manager.selectedTabId == manager.tabs[1].id)
    }

    /// Without the new-tab intent the opener still reselects, and a reselected tab is not the
    /// caller's to rewrite.
    @Test("Reselecting an existing tab leaves its filter state untouched")
    func reselectingLeavesFilterStateUntouched() throws {
        let connection = makeConnection()
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "customers", databaseType: .mysql, databaseName: "shop")
        let userFilter = TabFilterState(
            filters: [TableFilter(columnName: "country", filterOperator: .equal, value: "DE")],
            commit: .all,
            isVisible: true,
            filterLogicMode: .and
        )
        manager.mutate(at: 0) { $0.filterState = userFilter }

        EditorTabOpener.apply(
            EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: "customers",
                databaseName: "shop",
                isView: false,
                initialFilterState: TabFilterState(
                    filters: [TableFilter(columnName: "id", filterOperator: .equal, value: "42")],
                    commit: .all,
                    isVisible: true,
                    filterLogicMode: .and
                )
            ),
            to: manager,
            connection: connection,
            toolbarState: nil
        )

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].filterState == userFilter)
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
