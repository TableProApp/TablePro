import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("OpenTableTab")
struct OpenTableTabTests {
    // MARK: - Empty tabs path (no switching)

    @Test("Adds tab directly when tabs are empty and not switching")
    @MainActor
    func addsTabDirectlyWhenTabsEmptyNotSwitching() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.tableContext.tableName == "users")
        #expect(tabManager.tabs.first?.filterState.isVisible == false)
    }

    // MARK: - Window-local reuse (issue #1348)

    @Test("Reuses the active preview tab in place instead of opening a new tab")
    @MainActor
    func reusesActivePreviewTabInPlace() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addPreviewTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a")
        #expect(tabManager.tabs.count == 1)

        coordinator.openTableTab("orders")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
    }

    @Test("Reuses a blank query tab in place")
    @MainActor
    func reusesBlankQueryTabInPlace() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        tabManager.addTab(databaseName: "db_a")
        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tabType == .query)

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tabType == .table)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
        #expect(tabManager.selectedTab?.filterState.isVisible == false)
    }

    @Test("openTableTab converts a createTable tab in place after the table is created")
    @MainActor
    func convertsCreateTableTabInPlace() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        tabManager.addCreateTableTab(databaseName: "db_a")
        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tabType == .createTable)

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tabType == .table)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
    }

    @Test("Clicking the active table again is a no-op")
    @MainActor
    func clickingActiveTableAgainIsNoOp() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addPreviewTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a")
        let tabId = tabManager.selectedTab?.id

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == tabId)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
    }

    // MARK: - Schema identity resolution (issue #1774)

    @Test("Opening a bare table name stamps the session's current schema")
    @MainActor
    func bareTableNameResolvesActiveSchema() {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        coordinator.openTableTab("routes")

        #expect(tabManager.selectedTab?.tableContext.tableName == "routes")
        #expect(tabManager.selectedTab?.tableContext.schemaName == "sales")
    }

    @Test("Opening with an explicit schema wins over the session's current schema")
    @MainActor
    func explicitSchemaWinsOverActiveSchema() {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        coordinator.openTableTab("routes", schema: "audit")

        #expect(tabManager.selectedTab?.tableContext.schemaName == "audit")
    }

    @Test("Opening without a session leaves the schema nil")
    @MainActor
    func noSessionLeavesSchemaNil() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        coordinator.openTableTab("routes")

        #expect(tabManager.selectedTab?.tableContext.schemaName == nil)
    }

    // MARK: - isActiveTabReusable

    @Test("A preview table tab is reusable")
    @MainActor
    func previewTabIsReusable() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addPreviewTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        #expect(coordinator.isActiveTabReusable == true)
    }

    @Test("A permanent table tab is protected and not reusable")
    @MainActor
    func permanentTableTabIsNotReusable() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        #expect(coordinator.isActiveTabReusable == false)
    }

    @Test("A createTable tab without a committable design is reusable")
    @MainActor
    func createTableTabIsReusable() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addCreateTableTab(databaseName: "db")
        #expect(coordinator.isActiveTabReusable == true)
    }

    @Test("A createTable tab with a committable design is protected and not reusable")
    @MainActor
    func createTableTabWithPendingDesignIsNotReusable() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addCreateTableTab(databaseName: "db")
        coordinator.toolbarState.hasCreateTablePending = true
        #expect(coordinator.isActiveTabReusable == false)
    }

    @Test("A blank query tab is reusable")
    @MainActor
    func blankQueryTabIsReusable() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(databaseName: "db")
        #expect(coordinator.isActiveTabReusable == true)
    }

    @Test("A query tab with content is protected and not reusable")
    @MainActor
    func queryTabWithContentIsNotReusable() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db")
        #expect(coordinator.isActiveTabReusable == false)
    }

    // MARK: - Promotion (double-click / interaction)

    @Test("promotePreviewTab clears the preview flag and protects the tab")
    @MainActor
    func promoteClearsPreviewFlag() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addPreviewTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        #expect(coordinator.tabManager.selectedTab?.isPreview == true)

        coordinator.promotePreviewTab()

        #expect(coordinator.tabManager.selectedTab?.isPreview == false)
        #expect(coordinator.isActiveTabReusable == false)
    }

    @Test("promotePreviewTab is a no-op for a non-preview tab")
    @MainActor
    func promoteNonPreviewIsNoOp() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        coordinator.promotePreviewTab()
        #expect(coordinator.tabManager.selectedTab?.isPreview == false)
    }

    @Test("Double-click (forceNonPreview) replaces the preview tab with a permanent tab")
    @MainActor
    func forceNonPreviewReplacesWithPermanentTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addPreviewTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a")

        coordinator.openTableTab(
            TableInfo(name: "orders", type: .table, rowCount: nil),
            forceNonPreview: true
        )

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(tabManager.selectedTab?.isPreview == false)
    }

    // MARK: - Activate already-open tab (issue #1613)

    @Test("Clicking a table open in a non-selected tab selects it instead of duplicating")
    @MainActor
    func clickingTableInNonSelectedTabSelectsIt() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a")
        try tabManager.addTableTab(tableName: "orders", databaseType: connection.type, databaseName: "db_a")
        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
    }

    @Test("activateIfAlreadyOpen returns false when no open tab matches")
    @MainActor
    func activateIfAlreadyOpenReturnsFalseWhenNoMatch() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "orders", databaseType: connection.type, databaseName: "db_a")

        let activated = coordinator.activateIfAlreadyOpen(
            tableName: "users",
            databaseName: "db_a",
            schemaName: nil,
            showStructure: false,
            activateGridFocus: false,
            includeSiblings: true
        )

        #expect(activated == false)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
    }

    @Test("activateIfAlreadyOpen selects an existing in-window tab and applies structure mode")
    @MainActor
    func activateIfAlreadyOpenSelectsExistingTabWithStructure() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a")
        try tabManager.addTableTab(tableName: "orders", databaseType: connection.type, databaseName: "db_a")

        let activated = coordinator.activateIfAlreadyOpen(
            tableName: "users",
            databaseName: "db_a",
            schemaName: nil,
            showStructure: true,
            activateGridFocus: false,
            includeSiblings: true
        )

        #expect(activated == true)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
        #expect(tabManager.selectedTab?.display.resultsViewMode == .structure)
    }

    @MainActor
    private static func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }
}
