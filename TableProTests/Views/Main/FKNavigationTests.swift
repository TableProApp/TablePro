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
        session.driverSchema = "sales"
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
