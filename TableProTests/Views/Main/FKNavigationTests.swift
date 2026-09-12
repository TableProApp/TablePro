import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("FKNavigation")
struct FKNavigationTests {
    @Test("makeFKReferencePayload targets the referenced table and carries the FK filter")
    @MainActor
    func payloadCarriesFilterAndTarget() {
        let connection = TestFixtures.makeConnection(database: "db")
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        let filter = TableFilter(columnName: "id", filterOperator: .equal, value: "42")
        let payload = coordinator.makeFKReferencePayload(
            filter: filter,
            referencedTable: "users",
            databaseName: "db",
            schemaName: nil
        )

        #expect(payload.connectionId == connection.id)
        #expect(payload.tabType == .table)
        #expect(payload.tableName == "users")
        #expect(payload.databaseName == "db")
        #expect(payload.isView == false)
        #expect(payload.initialFilterState?.filters == [filter])
        #expect(payload.initialFilterState?.appliedFilters == [filter])
        #expect(payload.initialFilterState?.isVisible == true)
    }

    @Test("Plain click opens the reference in its own tab and leaves the table tab it came from")
    @MainActor
    func plainClickKeepsTheTableTabItCameFrom() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        #expect(tabManager.tabs.count == 1)
        let sourceTabId = tabManager.selectedTab?.id

        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == sourceTabId)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(opened.count == 1)
        #expect(opened.first?.tableName == "users")
        #expect(opened.first?.forcesNewTab == true)
        #expect(opened.first?.initialFilterState?.appliedFilters.first?.value == "42")
    }

    @Test("Plain click on the already-open referenced table does not open a second tab")
    @MainActor
    func plainClickOnSameTableStaysInPlace() throws {
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
            tableName: "users",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        let tabId = tabManager.selectedTab?.id
        #expect(tabManager.tabs.count == 1)

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == tabId)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
    }

    /// The target table has no rows yet, so the only thing that can type the value is its schema.
    /// Built from the empty buffer instead, `0123` went to a text key as the number `0123`, which
    /// MySQL compares numerically and PostgreSQL rejects outright.
    @Test("A hop within the same table types the reference value from that table's columns")
    @MainActor
    func sameTableHopTypesTheValueFromTheSchema() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        coordinator.schemaColumns.store(
            SchemaColumnStore.Entry(
                columns: ["id", "code"],
                primaryKeys: ["id"],
                columnTypes: ["id": .integer(rawType: "INT"), "code": .text(rawType: "VARCHAR(20)")]
            ),
            for: coordinator.schemaColumnsKey("orders", scope: coordinator.selectedTabScope)
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "code")
        coordinator.navigateToFKReference(value: "0123", fkInfo: fkInfo, intent: .follow)

        let query = try #require(tabManager.selectedTab?.content.query)
        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(query.contains("'0123'"))
        #expect(!query.contains("= 0123"))
    }

    @Test("FK navigation with no referenced schema resolves the session's current schema")
    @MainActor
    func nilReferencedSchemaResolvesActiveSchema() throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .postgresql)
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

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(opened.first?.tableName == "users")
        #expect(opened.first?.schemaName == "sales")
    }

    @Test("Plain click from an executed query tab opens a new tab and leaves the query tab intact")
    @MainActor
    func plainClickFromExecutedQueryTabOpensNewTab() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT * FROM orders", databaseName: coordinator.browseDatabaseName)
        tabManager.mutate(at: 0) { $0.execution.lastExecutedAt = Date() }
        let originalTabId = tabManager.selectedTab?.id

        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == originalTabId)
        #expect(tabManager.selectedTab?.tabType == .query)
        #expect(tabManager.selectedTab?.content.query == "SELECT * FROM orders")
        #expect(tabManager.selectedTab?.execution.lastExecutedAt != nil)
        #expect(opened.count == 1)
        #expect(opened.first?.tableName == "users")
        #expect(opened.first?.initialFilterState?.appliedFilters.first?.value == "42")
    }

    @Test("Plain click from a query tab with unexecuted SQL opens a new tab")
    @MainActor
    func plainClickFromTypedQueryTabOpensNewTab() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: coordinator.browseDatabaseName)
        let originalTabId = tabManager.selectedTab?.id

        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == originalTabId)
        #expect(tabManager.selectedTab?.tabType == .query)
        #expect(tabManager.selectedTab?.content.query == "SELECT 1")
        #expect(opened.count == 1)
    }

    @Test("Plain click from a table tab with pending edits leaves the edits in place")
    @MainActor
    func plainClickWithPendingEditsOpensNewTab() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        coordinator.changeManager.hasChanges = true

        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(opened.count == 1)
    }

    @Test("Clicking the same reference again returns to the tab it already opened")
    @MainActor
    func repeatedPlainClickActivatesExistingTargetTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")

        let originTabManager = QueryTabManager()
        let originCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: originTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        originCoordinator.registerEagerly()

        let targetTabManager = QueryTabManager()
        let targetCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: targetTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        targetCoordinator.registerEagerly()
        originCoordinator.hostedTabRouting = HostedTabRouting(
            coordinators: { _ in [targetCoordinator] },
            reveal: { coordinator, tabId in
                coordinator.tabManager.selectedTabId = tabId
                return true
            }
        )

        defer {
            originCoordinator.teardown()
            targetCoordinator.teardown()
        }

        originTabManager.addTab(
            initialQuery: "SELECT * FROM orders",
            databaseName: originCoordinator.browseDatabaseName
        )
        originTabManager.mutate(at: 0) { $0.execution.lastExecutedAt = Date() }

        try targetTabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: targetCoordinator.browseDatabaseName
        )
        targetTabManager.mutate(at: 0) {
            let applied = TableFilter(columnName: "id", filterOperator: .equal, value: "42")
            $0.filterState.filters = [applied]
            $0.filterState.commit = .all
            $0.filterState.executedFilters = [applied]
        }
        let existingTargetTabId = targetTabManager.selectedTab?.id

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(opened.isEmpty)
        #expect(originTabManager.tabs.count == 1)
        #expect(targetTabManager.tabs.count == 1)
        #expect(targetTabManager.selectedTab?.id == existingTargetTabId)
    }

    /// Revealing a tab elsewhere leaves the source behind the same way opening a new one does, so
    /// it has to be kept for the same reason: a preview tab the reader navigated away from would
    /// otherwise be retargeted by their next sidebar click.
    @Test("Revealing an open tab keeps the preview tab the reference was followed from")
    @MainActor
    func revealingAnOpenTabPromotesTheSourcePreviewTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")

        let originTabManager = QueryTabManager()
        let originCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: originTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        originCoordinator.registerEagerly()

        let targetTabManager = QueryTabManager()
        let targetCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: targetTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        targetCoordinator.registerEagerly()
        originCoordinator.hostedTabRouting = HostedTabRouting(
            coordinators: { _ in [targetCoordinator] },
            reveal: { coordinator, tabId in
                coordinator.tabManager.selectedTabId = tabId
                return true
            }
        )

        defer {
            originCoordinator.teardown()
            targetCoordinator.teardown()
        }

        try originTabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: originCoordinator.browseDatabaseName,
            isPreview: true
        )
        #expect(originTabManager.selectedTab?.isPreview == true)

        try targetTabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: targetCoordinator.browseDatabaseName
        )
        targetTabManager.mutate(at: 0) {
            let applied = TableFilter(columnName: "id", filterOperator: .equal, value: "42")
            $0.filterState.filters = [applied]
            $0.filterState.commit = .all
            $0.filterState.executedFilters = [applied]
        }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(originTabManager.tabs.count == 1)
        #expect(originTabManager.tabs[0].isPreview == false)
    }

    @Test("A reference to a different row does not re-filter a tab opened for another row")
    @MainActor
    func differentReferencedRowOpensItsOwnTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")

        let originTabManager = QueryTabManager()
        let originCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: originTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        originCoordinator.registerEagerly()

        let targetTabManager = QueryTabManager()
        let targetCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: targetTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        targetCoordinator.registerEagerly()
        originCoordinator.hostedTabRouting = HostedTabRouting(
            coordinators: { _ in [targetCoordinator] },
            reveal: { coordinator, tabId in
                coordinator.tabManager.selectedTabId = tabId
                return true
            }
        )

        defer {
            originCoordinator.teardown()
            targetCoordinator.teardown()
        }

        originTabManager.addTab(
            initialQuery: "SELECT * FROM orders",
            databaseName: originCoordinator.browseDatabaseName
        )
        originTabManager.mutate(at: 0) { $0.execution.lastExecutedAt = Date() }

        try targetTabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: targetCoordinator.browseDatabaseName
        )
        targetTabManager.mutate(at: 0) {
            let applied = TableFilter(columnName: "id", filterOperator: .equal, value: "42")
            $0.filterState.filters = [applied]
            $0.filterState.commit = .all
            $0.filterState.executedFilters = [applied]
        }

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "99", fkInfo: fkInfo, intent: .follow)

        #expect(opened.count == 1)
        #expect(opened.first?.initialFilterState?.appliedFilters.first?.value == "99")
        #expect(targetTabManager.selectedTab?.filterState.appliedFilters.first?.value == "42")
    }

    /// `appliedFilters` resolves from the panel's editable draft, so a filter row edited and not
    /// applied made a tab claim a reference it was not showing. Revealing it runs no query, so the
    /// reader landed on the rows the tab really held while the app reported it had found the row.
    @Test("A tab whose filter edit was never applied is not treated as showing the reference")
    @MainActor
    func anUnappliedFilterEditDoesNotCountAsShowingTheReference() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")

        let originTabManager = QueryTabManager()
        let originCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: originTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        originCoordinator.registerEagerly()

        let targetTabManager = QueryTabManager()
        let targetCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: targetTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        targetCoordinator.registerEagerly()
        originCoordinator.hostedTabRouting = HostedTabRouting(
            coordinators: { _ in [targetCoordinator] },
            reveal: { coordinator, tabId in
                coordinator.tabManager.selectedTabId = tabId
                return true
            }
        )

        defer {
            originCoordinator.teardown()
            targetCoordinator.teardown()
        }

        try originTabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: originCoordinator.browseDatabaseName
        )

        try targetTabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: targetCoordinator.browseDatabaseName
        )
        /// Fetched for 7, then edited to 42 in the panel without pressing Apply.
        targetTabManager.mutate(at: 0) {
            $0.filterState.executedFilters = [
                TableFilter(columnName: "id", filterOperator: .equal, value: "7"),
            ]
            $0.filterState.filters = [TableFilter(columnName: "id", filterOperator: .equal, value: "42")]
            $0.filterState.commit = .all
        }

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(opened.count == 1)
        #expect(opened.first?.tableName == "users")
        #expect(targetTabManager.tabs.count == 1)
    }

    /// A window hosts several connections, so a reveal that cannot put the tab in front of the
    /// reader has to open the reference rather than leave the click doing nothing.
    @Test("A reveal that cannot be shown falls back to opening the reference")
    @MainActor
    func anUnreachableRevealOpensTheReferenceInstead() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")

        let originTabManager = QueryTabManager()
        let originCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: originTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        originCoordinator.registerEagerly()

        let targetTabManager = QueryTabManager()
        let targetCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: targetTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        targetCoordinator.registerEagerly()
        originCoordinator.hostedTabRouting = HostedTabRouting(
            coordinators: { _ in [targetCoordinator] },
            reveal: { _, _ in false }
        )

        defer {
            originCoordinator.teardown()
            targetCoordinator.teardown()
        }

        try originTabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: originCoordinator.browseDatabaseName
        )

        try targetTabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: targetCoordinator.browseDatabaseName
        )
        targetTabManager.mutate(at: 0) {
            $0.filterState.executedFilters = [
                TableFilter(columnName: "id", filterOperator: .equal, value: "42"),
            ]
        }

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(opened.count == 1)
        #expect(opened.first?.tableName == "users")
    }

    @Test("Cmd-click opens a new tab even when the same reference is already open")
    @MainActor
    func explicitNewTabSkipsReuse() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")

        let originTabManager = QueryTabManager()
        let originCoordinator = MainContentCoordinator(
            connection: connection,
            tabManager: originTabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        originCoordinator.registerEagerly()
        defer { originCoordinator.teardown() }

        try originTabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: originCoordinator.browseDatabaseName
        )
        originTabManager.mutate(at: 0) {
            let applied = TableFilter(columnName: "id", filterOperator: .equal, value: "42")
            $0.filterState.filters = [applied]
            $0.filterState.commit = .all
            $0.filterState.executedFilters = [applied]
        }
        try originTabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: originCoordinator.browseDatabaseName
        )

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .newTab)

        #expect(opened.count == 1)
        #expect(originTabManager.selectedTab?.tableContext.tableName == "orders")
    }

    /// The hop that still records history is the one that stays in the tab: a reference into the
    /// table the tab is already showing. A jump that opens its own tab records nothing, because
    /// the tab it came from is still there to go back to.
    @Test("A hop within the same table records the source view, and Back restores it")
    @MainActor
    func sameTableHopRecordsHistoryAndBackRestoresIt() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        let outgoingFilter = TableFilter(columnName: "status", filterOperator: .equal, value: "open")
        tabManager.mutate(at: 0) {
            $0.filterState.filters = [outgoingFilter]
            $0.filterState.commit = .all
            $0.pagination.pageSize = 100
            $0.pagination.currentPage = 3
        }
        #expect(coordinator.canNavigateBack == false)

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        #expect(tabManager.selectedTab?.filterState.appliedFilters.first?.value == "42")
        #expect(coordinator.canNavigateBack)
        #expect(coordinator.canNavigateForward == false)

        coordinator.navigateBack()

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(tabManager.selectedTab?.filterState.appliedFilters.first?.value == "open")
        #expect(tabManager.selectedTab?.restoredPage == 3)
        #expect(tabManager.selectedTab?.restoredPageSize == 100)
        #expect(coordinator.canNavigateBack == false)
        #expect(coordinator.canNavigateForward)
    }

    @Test("Forward returns to the reference Back stepped away from")
    @MainActor
    func forwardReturnsToTheReference() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        coordinator.navigateBack()
        #expect(tabManager.selectedTab?.filterState.appliedFilters.isEmpty == true)

        coordinator.navigateForward()

        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(tabManager.selectedTab?.filterState.appliedFilters.first?.value == "42")
        #expect(coordinator.canNavigateForward == false)
        #expect(coordinator.canNavigateBack)
    }

    @Test("A hop after Back discards the forward stack")
    @MainActor
    func hopAfterBackTruncatesForward() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let byId = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: byId, intent: .follow)
        coordinator.navigateBack()
        #expect(coordinator.canNavigateForward)

        coordinator.navigateToFKReference(value: "7", fkInfo: byId, intent: .follow)

        #expect(tabManager.selectedTab?.filterState.appliedFilters.first?.value == "7")
        #expect(coordinator.canNavigateForward == false)
        #expect(coordinator.canNavigateBack)
    }

    @Test("A hop that opens its own tab leaves the source tab with no history")
    @MainActor
    func newTabHopRecordsNoHistory() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .newTab)

        #expect(opened.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(coordinator.canNavigateBack == false)
    }

    @Test("Clicking the reference the tab already shows records no second entry")
    @MainActor
    func repeatedSameReferenceRecordsOnce() throws {
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
            tableName: "users",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        #expect(coordinator.canNavigateBack)

        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        coordinator.navigateBack()

        #expect(coordinator.canNavigateBack == false)
    }

    /// Back stays offered with unsaved edits, and asks before it discards them, the way refresh,
    /// sort, pagination and filter already do. It used to refuse instead, which left the control
    /// dim over a destination that still existed with nothing saying why.
    ///
    /// The step is not asserted here: with changes staged, `confirmDiscardChangesIfNeeded` puts a
    /// real alert on screen, which a unit test cannot answer. What this pins is the availability,
    /// which is what the toolbar and the View menu both read.
    @Test("Back stays offered while the tab holds unsaved edits")
    @MainActor
    func backStaysOfferedWithPendingEdits() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        #expect(coordinator.canNavigateBack)

        coordinator.changeManager.hasChanges = true

        #expect(coordinator.canNavigateBack, "Unsaved edits are a prompt, not a refusal")
    }

    /// The one thing navigation still refuses outright. The discard alert clears `changeManager`
    /// and nothing else, so offering to discard a staged structure edit would be a promise this
    /// path cannot keep.
    @Test("Back stands down while the tab holds staged structure edits")
    @MainActor
    func backIsUnavailableWithStagedStructureEdits() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        #expect(coordinator.canNavigateBack)

        let tabId = try #require(tabManager.selectedTabId)
        let session = TestFixtures.makeStructureSession()
        coordinator.structureSessions[tabId] = session
        session.changeManager.loadSchema(
            tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
        )
        session.changeManager.addNewColumn()

        #expect(coordinator.canNavigateBack == false)
    }

    @Test("Closing a tab takes its history with it")
    @MainActor
    func closingATabDropsItsHistory() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        let tabId = try #require(tabManager.selectedTab?.id)
        #expect(coordinator.navigationHistories[tabId]?.canGoBack == true)

        coordinator.closeTabsByUser(ids: [tabId])

        #expect(coordinator.navigationHistories[tabId] == nil)
    }

    @Test("A sidebar open that reuses the tab records the view it replaced")
    @MainActor
    func sidebarRetargetRecordsHistory() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName,
            isPreview: true
        )
        #expect(coordinator.canNavigateBack == false)

        coordinator.openTableTab("customers")

        #expect(tabManager.selectedTab?.tableContext.tableName == "customers")
        #expect(coordinator.canNavigateBack)

        coordinator.navigateBack()

        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
    }

    @Test("Back restores the page size even for a view recorded on the first page")
    @MainActor
    func backRestoresPageSizeOnFirstPage() throws {
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
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        tabManager.mutate(at: 0) {
            $0.pagination.pageSize = 500
            $0.pagination.currentPage = 1
        }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "orders", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)
        coordinator.navigateBack()

        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")
        #expect(tabManager.selectedTab?.restoredPageSize == 500)
    }

    @Test("A pending row anchor belongs to one tab and no other tab can take it")
    @MainActor
    func rowAnchorIsKeyedByTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        let owning = UUID()
        let other = UUID()
        coordinator.pendingRowAnchors[owning] = ["id": "4021"]

        #expect(coordinator.pendingRowAnchors[other] == nil)
        #expect(coordinator.pendingRowAnchors.removeValue(forKey: owning) == ["id": "4021"])
        #expect(coordinator.pendingRowAnchors[owning] == nil)
    }

    @Test("Metadata is not cached until foreign keys were fetched")
    @MainActor
    func metadataCacheRequiresFetchedForeignKeys() throws {
        let connection = TestFixtures.makeConnection(database: "db")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        let tabId = tabManager.tabs[0].id
        tabManager.mutate(at: 0) { $0.tableContext.primaryKeyColumns = ["id"] }

        var rows = TableRows.from(
            queryRows: [],
            columns: ["id"],
            columnTypes: [],
            columnDefaults: ["id": nil]
        )
        coordinator.setActiveTableRows(rows, for: tabId)
        let cachedBefore = coordinator.queryExecutionCoordinator.isMetadataCached(tabId: tabId, tableName: "orders")
        #expect(cachedBefore == false)

        _ = rows.updateDisplayMetadata(columnForeignKeys: [:])
        coordinator.setActiveTableRows(rows, for: tabId)
        let cachedAfter = coordinator.queryExecutionCoordinator.isMetadataCached(tabId: tabId, tableName: "orders")
        #expect(cachedAfter)
    }

    // MARK: - The referenced namespace

    /// MySQL reports `REFERENCED_TABLE_SCHEMA`, which names the referenced DATABASE, so carrying it
    /// into `schemaName` gave the table a second identity: its own filters, column layout, highlight
    /// rules and Display As, a title reading `db_a.users`, and no tab for the sidebar to reuse.
    @Test("A schema-less engine keeps the referenced database out of the tab's schema")
    @MainActor
    func schemaLessReferenceLeavesSchemaEmpty() throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(
            referencedTable: "users", referencedColumn: "id", referencedSchema: "db_a"
        )
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        let context = try #require(opened.first)
        #expect(context.tableName == "users")
        #expect(context.schemaName == nil)
        #expect(context.databaseName == "db_a")
    }

    @Test("A schema-less engine follows a reference into another database")
    @MainActor
    func schemaLessReferenceCrossesDatabases() throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(
            referencedTable: "tenants", referencedColumn: "id", referencedSchema: "billing"
        )
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        let context = try #require(opened.first)
        #expect(context.tableName == "tenants")
        #expect(context.databaseName == "billing")
        #expect(context.schemaName == nil)
    }

    @Test("An engine with schemas still carries the referenced schema")
    @MainActor
    func schemaEngineKeepsTheReferencedSchema() throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .postgresql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName,
            schemaName: "public"
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(
            referencedTable: "users", referencedColumn: "id", referencedSchema: "audit"
        )
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        let context = try #require(opened.first)
        #expect(context.tableName == "users")
        #expect(context.schemaName == "audit")
        #expect(context.databaseName == "db_a")
    }

    /// A tab persisted before the referenced database stopped being read as a schema still carries
    /// one. Coalescing the resolved schema with the source's put that stale value straight back on
    /// the next hop, so the identity the resolver had just cleared returned one navigation later.
    @Test("A stale schema on the source tab does not reach the table a key opens")
    @MainActor
    func staleSourceSchemaIsNotCarriedForward() throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName,
            schemaName: "db_a"
        )

        let fkInfo = TestFixtures.makeForeignKeyInfo(
            referencedTable: "tenants", referencedColumn: "id", referencedSchema: "billing"
        )
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, intent: .follow)

        let context = try #require(opened.first)
        #expect(context.tableName == "tenants")
        #expect(context.databaseName == "billing")
        #expect(context.schemaName == nil)
    }
}
