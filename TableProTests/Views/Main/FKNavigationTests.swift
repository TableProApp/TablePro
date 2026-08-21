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

    @Test("Plain click navigates the referenced table into the current tab")
    @MainActor
    func plainClickReplacesCurrentTab() throws {
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

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
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
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == tabId)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
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

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
        #expect(tabManager.selectedTab?.tableContext.schemaName == "sales")
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
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

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
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

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
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

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
            $0.filterState.filters = [TableFilter(columnName: "id", filterOperator: .equal, value: "42")]
            $0.filterState.commit = .all
        }
        let existingTargetTabId = targetTabManager.selectedTab?.id

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(opened.isEmpty)
        #expect(originTabManager.tabs.count == 1)
        #expect(targetTabManager.tabs.count == 1)
        #expect(targetTabManager.selectedTab?.id == existingTargetTabId)
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
            $0.filterState.filters = [TableFilter(columnName: "id", filterOperator: .equal, value: "42")]
            $0.filterState.commit = .all
        }

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "99", fkInfo: fkInfo, openInNewTab: false)

        #expect(opened.count == 1)
        #expect(opened.first?.initialFilterState?.appliedFilters.first?.value == "99")
        #expect(targetTabManager.selectedTab?.filterState.appliedFilters.first?.value == "42")
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
            $0.filterState.filters = [TableFilter(columnName: "id", filterOperator: .equal, value: "42")]
            $0.filterState.commit = .all
        }
        try originTabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: originCoordinator.browseDatabaseName
        )

        var opened: [EditorTabPayload] = []
        originCoordinator.openTabInNewWindow = { opened.append($0) }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        originCoordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: true)

        #expect(opened.count == 1)
        #expect(originTabManager.selectedTab?.tableContext.tableName == "orders")
    }

    @Test("An in-place hop saves the outgoing table's filters and restores the target's hidden columns")
    @MainActor
    func inPlaceHopKeepsPerTableSettings() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        let ordersKey = ColumnLayoutTableKey(
            connectionId: connection.id,
            databaseName: coordinator.browseDatabaseName,
            schemaName: nil,
            tableName: "orders"
        )
        let usersKey = ColumnLayoutTableKey(
            connectionId: connection.id,
            databaseName: coordinator.browseDatabaseName,
            schemaName: nil,
            tableName: "users"
        )
        defer {
            FileColumnLayoutPersister.shared.clear(for: ordersKey)
            FileColumnLayoutPersister.shared.clear(for: usersKey)
            FilterSettingsStorage.shared.clearLastFilters(
                for: "orders",
                connectionId: connection.id,
                databaseName: coordinator.browseDatabaseName,
                schemaName: nil
            )
        }
        FileColumnLayoutPersister.shared.saveHiddenColumns(["ssn"], for: usersKey)

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.browseDatabaseName
        )
        let outgoingFilter = TableFilter(columnName: "status", filterOperator: .equal, value: "open")
        tabManager.mutate(at: 0) {
            $0.filterState.filters = [outgoingFilter]
            $0.filterState.commit = .all
        }

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
        #expect(tabManager.selectedTab?.columnLayout.hiddenColumns == ["ssn"])

        let savedForOrders = FilterSettingsStorage.shared.loadLastFilters(
            for: "orders",
            connectionId: connection.id,
            databaseName: coordinator.browseDatabaseName,
            schemaName: nil
        )
        #expect(savedForOrders.contains { $0.columnName == "status" && $0.value == "open" })
    }

    @Test("An in-place hop records the source view, and Back restores it")
    @MainActor
    func inPlaceHopRecordsHistoryAndBackRestoresIt() throws {
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

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
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

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)
        coordinator.navigateBack()
        #expect(tabManager.selectedTab?.tableContext.tableName == "orders")

        coordinator.navigateForward()

        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
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

        let users = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: users, openInNewTab: false)
        coordinator.navigateBack()
        #expect(coordinator.canNavigateForward)

        let regions = TestFixtures.makeForeignKeyInfo(referencedTable: "regions", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "7", fkInfo: regions, openInNewTab: false)

        #expect(tabManager.selectedTab?.tableContext.tableName == "regions")
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
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: true)

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
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)
        #expect(coordinator.canNavigateBack)

        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)
        coordinator.navigateBack()

        #expect(coordinator.canNavigateBack == false)
    }

    @Test("Back stands down while the tab holds unsaved edits")
    @MainActor
    func backIsUnavailableWithPendingEdits() throws {
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

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)
        #expect(coordinator.canNavigateBack)

        coordinator.changeManager.hasChanges = true

        #expect(coordinator.canNavigateBack == false)
        coordinator.navigateBack()
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
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
        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)
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

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)
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

    @Test("Retargeting a tab drops a row anchor its navigation never used")
    @MainActor
    func retargetDropsAStaleRowAnchor() throws {
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
        let tabId = try #require(tabManager.selectedTab?.id)
        coordinator.pendingRowAnchors[tabId] = ["id": "4021"]

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(coordinator.pendingRowAnchors[tabId] == nil)
    }

    @Test("An in-place hop cancels the outgoing tab's in-flight load")
    @MainActor
    func inPlaceHopCancelsInFlightLoad() throws {
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
        guard let tabId = tabManager.selectedTab?.id else {
            Issue.record("expected a selected tab")
            return
        }

        let inFlight = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        coordinator.tableLoadTasks[tabId] = (token: UUID(), task: inFlight)

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(inFlight.isCancelled)
        #expect(coordinator.tableLoadTasks[tabId] == nil)
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
}
