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

        try tabManager.addTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a", isPreview: true)
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

        try tabManager.addTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a", isPreview: true)
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
        session.browseSchema = "sales"
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
        session.browseSchema = "sales"
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
        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db", isPreview: true)
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
        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db", isPreview: true)
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

    /// The whole point of keeping a tab: the next table opened from the sidebar gets one of its
    /// own instead of taking this one over. (#2436)
    @Test("A kept tab is not reused by the next table opened from the sidebar")
    @MainActor
    func keptTabIsNotReusedByTheNextOpen() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "users", databaseType: connection.type, databaseName: "db_a", isPreview: true
        )
        let keptTabId = try #require(tabManager.selectedTabId)
        #expect(coordinator.isActiveTabReusable)

        tabManager.promotePreviewTab(id: keptTabId)

        #expect(coordinator.isActiveTabReusable == false)
        #expect(tabManager.tabs.first { $0.id == keptTabId }?.tableContext.tableName == "users")
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

        try tabManager.addTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a", isPreview: true)

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

        #expect(activated == nil)
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

        #expect(activated == .currentCoordinator)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
        #expect(tabManager.selectedTab?.display.resultsViewMode == .structure)
    }

    // MARK: - Protected content

    @Test("An executed query tab holds protected content")
    @MainActor
    func executedQueryTabIsProtected() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(databaseName: "db")
        coordinator.tabManager.mutate(at: 0) { $0.execution.lastExecutedAt = Date() }
        #expect(coordinator.selectedTabHoldsProtectedContent)
    }

    @Test("A query tab with typed but unexecuted SQL holds protected content")
    @MainActor
    func typedQueryTabIsProtected() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db")
        #expect(coordinator.selectedTabHoldsProtectedContent)
    }

    @Test("A blank never-executed query tab holds no protected content")
    @MainActor
    func blankQueryTabIsNotProtected() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(databaseName: "db")
        #expect(coordinator.selectedTabHoldsProtectedContent == false)
    }

    /// Single-clicking another table reuses a preview tab in place. The reuse gate consulted the
    /// data-grid change manager and the query text but never the tab's staged ALTERs, so a preview
    /// tab holding a renamed column was retargeted with no prompt of any kind and the work was gone.
    @Test("Staged structure edits hold a preview tab against reuse")
    @MainActor
    func stagedStructureEditsAreProtected() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addTableTab(
            tableName: "users", databaseType: .mysql, databaseName: "db_a", isPreview: true
        )
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        #expect(coordinator.selectedTabHoldsProtectedContent == false)

        let session = TestFixtures.makeStructureSession()
        coordinator.structureSessions[id] = session
        session.changeManager.loadSchema(
            tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
        )
        session.changeManager.addNewColumn()

        #expect(coordinator.selectedTabHoldsProtectedContent)
        #expect(coordinator.isActiveTabReusable == false)
    }

    /// A retarget keeps the tab id and changes what it means, so the caches keyed on that id
    /// describe a table the tab no longer shows. The session used to survive, and went on raising
    /// an unsaved-changes prompt naming the previous table.
    @Test("Retargeting a tab releases the structure session keyed to it")
    @MainActor
    func retargetReleasesTheStructureSession() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addTableTab(
            tableName: "users", databaseType: .mysql, databaseName: "db_a", isPreview: true
        )
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.structureSessions[id] = TestFixtures.makeStructureSession()

        _ = try coordinator.tabManager.replaceTabContent(tableName: "orders", databaseName: "db_a")

        #expect(coordinator.structureSessions[id] == nil)
    }

    @Test("A table tab with pending cell edits holds protected content")
    @MainActor
    func tableTabWithPendingEditsIsProtected() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        coordinator.changeManager.hasChanges = true
        #expect(coordinator.selectedTabHoldsProtectedContent)
    }

    @Test("An ordinary table tab holds no protected content")
    @MainActor
    func ordinaryTableTabIsNotProtected() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        #expect(coordinator.selectedTabHoldsProtectedContent == false)
    }

    @Test("A createTable tab with a committable design holds protected content")
    @MainActor
    func createTableTabWithPendingDesignIsProtected() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addCreateTableTab(databaseName: "db")
        coordinator.toolbarState.hasCreateTablePending = true
        #expect(coordinator.selectedTabHoldsProtectedContent)
    }

    @Test("A createTable tab without a committable design holds no protected content")
    @MainActor
    func createTableTabWithoutPendingDesignIsNotProtected() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addCreateTableTab(databaseName: "db")
        #expect(coordinator.selectedTabHoldsProtectedContent == false)
    }

    // MARK: - Keeping a tab (issue #2235)

    /// The gesture that says "keep this one" lands on a table the sidebar has already previewed,
    /// so it has to reach a tab that exists rather than only tabs it creates.
    @Test("forceNonPreview promotes the already-open preview tab it activates")
    @MainActor
    func forceNonPreviewPromotesTheActivatedTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "users", databaseType: connection.type, databaseName: "db_a", isPreview: true
        )
        #expect(tabManager.selectedTab?.isPreview == true)

        coordinator.openTableTab("users", forceNonPreview: true)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.isPreview == false)
        #expect(coordinator.isActiveTabReusable == false)
    }

    /// Keeping one table's tab is what lets the next table have its own, which is the whole of the
    /// reporter's A then B then A sequence.
    @Test("After a promotion, opening a second table adds a tab instead of replacing")
    @MainActor
    func promotedTabIsNotReplacedByTheNextOpen() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        var opened: [EditorTabPayload] = []
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }
        coordinator.openTabInNewWindow = { opened.append($0) }

        try tabManager.addTableTab(
            tableName: "users", databaseType: connection.type, databaseName: "db_a", isPreview: true
        )
        coordinator.openTableTab("users", forceNonPreview: true)
        coordinator.openTableTab("orders")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
        #expect(opened.count == 1)
        #expect(opened.first?.tableName == "orders")
        #expect(opened.first?.forcesNewTab == false)
    }

    @Test("Open in New Tab hands the new-tab intent to the payload")
    @MainActor
    func forceNewTabCarriesTheIntentOnThePayload() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        var opened: [EditorTabPayload] = []
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }
        coordinator.openTabInNewWindow = { opened.append($0) }

        try tabManager.addTableTab(tableName: "users", databaseType: connection.type, databaseName: "db_a")

        coordinator.openTableTab("users", forceNewTab: true)

        #expect(opened.count == 1)
        #expect(opened.first?.tableName == "users")
        #expect(opened.first?.forcesNewTab == true)
        #expect(opened.first?.isPreview == false)
    }

    /// Array order would send a click on the table you are looking at to the other copy of it.
    @Test("Activating a duplicated table keeps the tab that is already selected")
    @MainActor
    func activatingADuplicatedTableKeepsTheSelectedTab() throws {
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
        let firstTabId = try #require(tabManager.selectedTabId)
        try tabManager.addTableTab(
            tableName: "users", databaseType: connection.type, databaseName: "db_a", allowsDuplicate: true
        )
        let secondTabId = try #require(tabManager.selectedTabId)
        #expect(firstTabId != secondTabId)

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.selectedTabId == secondTabId)
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
