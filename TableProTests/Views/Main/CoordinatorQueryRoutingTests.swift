import Foundation
import Testing

@testable import TablePro

@Suite("CoordinatorQueryRouting")
struct CoordinatorQueryRoutingTests {
    @MainActor
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let connection = TestFixtures.makeConnection(database: "testdb")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        coordinator.openTabInNewWindow = { _ in }
        coordinator.connectionExists = { _ in true }
        return (coordinator, tabManager)
    }

    @Test("A query from this connection replaces the front tab and claims its focus")
    @MainActor
    func loadsIntoTheFrontTab() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "testdb")

        coordinator.openQuery(
            "SELECT * FROM Genre",
            on: coordinator.connectionId,
            databaseName: "testdb",
            intent: .loadIntoFrontTab
        )

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs[0].content.query == "SELECT * FROM Genre")
        #expect(tabManager.pendingFocusTabId == tabManager.tabs[0].id)
    }

    @Test("Forcing a new tab leaves the front tab alone and carries the entry's database")
    @MainActor
    func opensASecondTab() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "testdb")

        coordinator.openQuery(
            "SELECT * FROM Genre",
            on: coordinator.connectionId,
            databaseName: "analytics",
            intent: .runInNewTab
        )

        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.tabs[0].content.query == "SELECT 1")
        #expect(tabManager.tabs[1].content.query == "SELECT * FROM Genre")
        #expect(tabManager.tabs[1].tableContext.databaseName == "analytics")
        #expect(tabManager.pendingFocusTabId == tabManager.tabs[1].id)
    }

    /// The drawer lists other connections' queries once the scope widens, and running one of those
    /// against whatever is in front of the user is worse than the dead click this replaced.
    @Test("A query from another connection goes to that connection, never into this tab list")
    @MainActor
    func routesAForeignQueryToItsOwnConnection() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: EditorTabPayload?
        coordinator.openTabInNewWindow = { opened = $0 }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "testdb")
        let otherConnectionId = UUID()

        coordinator.openQuery(
            "SELECT * FROM Genre",
            on: otherConnectionId,
            databaseName: "warehouse",
            intent: .loadIntoFrontTab
        )

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs[0].content.query == "SELECT 1")
        #expect(opened?.connectionId == otherConnectionId)
        #expect(opened?.databaseName == "warehouse")
        #expect(opened?.initialQuery == "SELECT * FROM Genre")
        #expect(opened?.tabType == .query)
    }

    /// Deleting a connection deletes its history with it, so an id that resolves to nothing means
    /// the two stores disagree. Opening a window onto a connection that is gone is not a recovery.
    /// A connection opened without a default database records its queries against "", which is not
    /// the name of a database any tab can be browsing.
    @Test("An entry recorded with no database still fills the tab in front")
    @MainActor
    func treatsAnEmptyDatabaseAsUnset() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: EditorTabPayload?
        coordinator.openTabInNewWindow = { opened = $0 }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "app")

        coordinator.openQuery(
            "SELECT * FROM Genre",
            on: coordinator.connectionId,
            databaseName: "",
            intent: .loadIntoFrontTab
        )

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs[0].content.query == "SELECT * FROM Genre")
        #expect(opened == nil)
    }

    /// The execution gate drops a dispatch while a confirmation is already up, so a tab opened
    /// before that check would sit there carrying a query that never ran.
    @Test("Run in New Tab opens no tab while a confirmation is already up")
    @MainActor
    func opensNoTabWhileAPromptIsUp() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.isShowingSafeModePrompt = true

        coordinator.openQuery(
            "DELETE FROM Genre WHERE GenreId = 1",
            on: coordinator.connectionId,
            databaseName: "testdb",
            intent: .runInNewTab
        )

        #expect(tabManager.tabs.isEmpty)
    }

    @Test("A query whose connection no longer exists opens no window")
    @MainActor
    func refusesAQueryFromADeletedConnection() {
        let (coordinator, _) = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: EditorTabPayload?
        coordinator.openTabInNewWindow = { opened = $0 }
        coordinator.connectionExists = { _ in false }
        var reportedErrors = 0
        coordinator.presentError = { _, _, _ in reportedErrors += 1 }

        coordinator.openQuery(
            "SELECT * FROM Genre",
            on: UUID(),
            databaseName: "warehouse",
            intent: .loadIntoFrontTab
        )

        #expect(opened == nil)
        #expect(reportedErrors == 1)
    }

    @Test("A blank query opens nothing at all")
    @MainActor
    func ignoresABlankQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: EditorTabPayload?
        coordinator.openTabInNewWindow = { opened = $0 }

        coordinator.openQuery(
            "   \n\t ",
            on: coordinator.connectionId,
            databaseName: "testdb",
            intent: .runInNewTab
        )

        #expect(tabManager.tabs.isEmpty)
        #expect(opened == nil)
    }

    @Test("A query for a database no tab is browsing opens its own tab instead of overwriting one")
    @MainActor
    func doesNotOverwriteATabFromAnotherDatabase() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: EditorTabPayload?
        coordinator.openTabInNewWindow = { opened = $0 }

        tabManager.addTab(initialQuery: "SELECT private_data", databaseName: "primary")

        coordinator.openQuery(
            "SELECT public_data",
            on: coordinator.connectionId,
            databaseName: "analytics",
            intent: .loadIntoFrontTab
        )

        #expect(tabManager.tabs[0].content.query == "SELECT private_data")
        #expect(opened?.databaseName == "analytics")
        #expect(opened?.initialQuery == "SELECT public_data")
    }
}
