//
//  DatabaseTreeReconcileTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// The outline's services publish for every connection and every property; only a change to what this
// connection's outline draws may rebuild it.
@MainActor
struct DatabaseTreeReconcileTests {
    private final class CountingOutlineView: NSOutlineView {
        var reloads = 0
        var insertedRows = 0
        var removedRows = 0
        var reloadedParents = 0

        var rowOperations: Int {
            insertedRows + removedRows + reloadedParents
        }

        override func reloadData() {
            reloads += 1
            super.reloadData()
        }

        override func insertItems(
            at indexes: IndexSet,
            inParent parent: Any?,
            withAnimation animationOptions: NSTableView.AnimationOptions = []
        ) {
            insertedRows += indexes.count
            super.insertItems(at: indexes, inParent: parent, withAnimation: animationOptions)
        }

        override func removeItems(
            at indexes: IndexSet,
            inParent parent: Any?,
            withAnimation animationOptions: NSTableView.AnimationOptions = []
        ) {
            removedRows += indexes.count
            super.removeItems(at: indexes, inParent: parent, withAnimation: animationOptions)
        }

        override func reloadItem(_ item: Any?, reloadChildren: Bool) {
            reloadedParents += 1
            super.reloadItem(item, reloadChildren: reloadChildren)
        }
    }

    private struct Fixture {
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver
        let coordinator: DatabaseTreeOutlineCoordinator
        let outlineView: CountingOutlineView
        let sidebarState: SharedSidebarState
        let viewModel: SidebarViewModel
        let scrollView: NSScrollView
    }

    private func makeFixture() async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "customers")]
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection)

        let outlineView = CountingOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "ReconcileColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = .flat
        let viewModel = SidebarViewModel(
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .mysql,
            connectionId: connection.id
        )
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .mysql
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = "shop"
        coordinator.showRecentTables = true
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(
            connection: connection,
            driver: driver,
            coordinator: coordinator,
            outlineView: outlineView,
            sidebarState: sidebarState,
            viewModel: viewModel,
            scrollView: scrollView
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        await SchemaService.shared.invalidate(connectionId: fixture.connection.id)
        SharedSidebarState.removeConnection(fixture.connection.id)
        _ = fixture.scrollView
        _ = fixture.viewModel
    }

    private func tableRows(_ fixture: Fixture) throws -> [DatabaseTreeNode] {
        let section = try #require(fixture.coordinator.resolvedChildren(of: nil).first { node in
            guard case .objectKindSection(.table) = node.kind else { return false }
            return true
        })
        return fixture.coordinator.resolvedChildren(of: section)
    }

    private func tableNames(_ fixture: Fixture) throws -> [String] {
        try tableRows(fixture).compactMap { node -> String? in
            guard case .table(let ref) = node.kind else { return nil }
            return ref.table.name
        }
    }

    @Test("A catalog load on another connection does not reload the outline")
    func otherConnectionDoesNotReload() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads
        let other = TestFixtures.makeConnection(database: "blog", type: .mysql)
        let otherDriver = MockDatabaseDriver(connection: other)
        otherDriver.tablesToReturn = [TestFixtures.makeTableInfo(name: "posts")]

        await SchemaService.shared.load(connectionId: other.id, driver: otherDriver, connection: other)
        fixture.coordinator.reconcile()

        #expect(fixture.outlineView.reloads == reloads)
        await SchemaService.shared.invalidate(connectionId: other.id)
        await tearDown(fixture)
    }

    private func reload(_ fixture: Fixture, tables: [TableInfo]) async {
        fixture.driver.tablesToReturn = tables
        await SchemaService.shared.reload(
            connectionId: fixture.connection.id, driver: fixture.driver, connection: fixture.connection
        )
        fixture.coordinator.reconcile()
    }

    private func tableRow(_ fixture: Fixture, named name: String) throws -> DatabaseTreeNode {
        try #require(try tableRows(fixture).first { node in
            guard case .table(let ref) = node.kind else { return false }
            return ref.table.name == name
        })
    }

    private func select(_ fixture: Fixture, named name: String) throws -> DatabaseTreeTableRef {
        let node = try tableRow(fixture, named: name)
        let ref = try #require(node.tableRef)
        fixture.coordinator.windowState?.selectTables([ref])
        fixture.coordinator.syncSelectionToModel()
        #expect(fixture.outlineView.selectedRow == fixture.outlineView.row(forItem: node))
        return ref
    }

    @Test("A change to this connection's tables reaches the outline as row changes, without a reload")
    func ownTablesChangeRows() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads

        await reload(fixture, tables: [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "invoices")])

        #expect(try tableNames(fixture) == ["orders", "invoices"])
        #expect(fixture.outlineView.reloads == reloads)
        #expect(fixture.outlineView.insertedRows == 1)
        #expect(fixture.outlineView.removedRows == 1)
        #expect(fixture.outlineView.row(forItem: try tableRow(fixture, named: "invoices")) >= 0)
        await tearDown(fixture)
    }

    @Test("Reading the same rows again touches no row")
    func sameRowsTouchNothing() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads
        let nodes = try tableRows(fixture)

        await reload(fixture, tables: [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "customers")])

        #expect(fixture.outlineView.reloads == reloads)
        #expect(fixture.outlineView.rowOperations == 0)
        #expect(SameRows(rows: try tableRows(fixture)) == SameRows(rows: nodes))
        await tearDown(fixture)
    }

    @Test("A table added beside the selected one leaves the selection on it")
    func insertionKeepsSelection() async throws {
        let fixture = try await makeFixture()
        let ref = try select(fixture, named: "customers")
        let orders = try tableRow(fixture, named: "orders")
        let customers = try tableRow(fixture, named: "customers")

        await reload(fixture, tables: [
            TestFixtures.makeTableInfo(name: "accounts"),
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "customers")
        ])

        #expect(fixture.outlineView.insertedRows == 1)
        #expect(try tableRow(fixture, named: "orders") === orders)
        #expect(try tableRow(fixture, named: "customers") === customers)
        #expect(fixture.coordinator.nodeCache[orders.id] === orders)
        #expect(fixture.outlineView.selectedRow == fixture.outlineView.row(forItem: try tableRow(fixture, named: "customers")))
        #expect(fixture.coordinator.windowState?.selectedTables == [ref])
        await tearDown(fixture)
    }

    @Test("Dropping the selected table empties the highlight and leaves the model's selection alone")
    func removalKeepsTheModelSelection() async throws {
        let fixture = try await makeFixture()
        let ref = try select(fixture, named: "customers")

        await reload(fixture, tables: [TestFixtures.makeTableInfo(name: "orders")])

        #expect(try tableNames(fixture) == ["orders"])
        #expect(fixture.outlineView.removedRows == 1)
        #expect(fixture.outlineView.selectedRow == -1)
        #expect(fixture.coordinator.windowState?.selectedTables == [ref])
        await tearDown(fixture)
    }

    @Test("A new comment on a kept table writes the row in place")
    func commentChangeKeepsTheRow() async throws {
        let fixture = try await makeFixture()
        let node = try tableRow(fixture, named: "orders")
        let reloads = fixture.outlineView.reloads

        await reload(fixture, tables: [
            TableInfo(name: "orders", type: .table, rowCount: 0, comment: "Paid and unpaid"),
            TestFixtures.makeTableInfo(name: "customers")
        ])

        #expect(try tableRow(fixture, named: "orders") === node)
        #expect(node.tableRef?.table.comment == "Paid and unpaid")
        #expect(fixture.outlineView.reloads == reloads)
        #expect(fixture.outlineView.rowOperations == 0)
        await tearDown(fixture)
    }

    @Test("The rows on screen are drawn again after a change, so a kept row shows what it now holds")
    func keptRowsAreRedrawn() async throws {
        let fixture = try await makeFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = fixture.scrollView
        fixture.outlineView.layoutSubtreeIfNeeded()
        let row = fixture.outlineView.row(forItem: try tableRow(fixture, named: "orders"))
        let cell = try #require(fixture.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DatabaseTreeCellView)
        let hosting = try #require(cell.hostedView as? NSHostingView<DatabaseTreeRowView>)
        #expect(hosting.rootView.context.activeDatabase == "shop")
        let reloads = fixture.outlineView.reloads

        fixture.coordinator.activeDatabase = "archive"
        await reload(fixture, tables: [
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "customers"),
            TestFixtures.makeTableInfo(name: "invoices")
        ])

        #expect(fixture.outlineView.reloads == reloads)
        #expect(hosting.rootView.context.activeDatabase == "archive")
        window.orderOut(nil)
        await tearDown(fixture)
    }

    @Test("A section closed during a change lists the new rows when it opens")
    func closedSectionOpensOnNewRows() async throws {
        let fixture = try await makeFixture()
        let section = try #require(fixture.coordinator.resolvedChildren(of: nil).first { node in
            guard case .objectKindSection(.table) = node.kind else { return false }
            return true
        })
        fixture.viewModel.expanded[.table] = false
        fixture.outlineView.collapseItem(section)

        await reload(fixture, tables: [
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "customers"),
            TestFixtures.makeTableInfo(name: "invoices")
        ])
        fixture.outlineView.expandItem(section)

        #expect(fixture.outlineView.numberOfChildren(ofItem: section) == 3)
        #expect(fixture.outlineView.row(forItem: try tableRow(fixture, named: "invoices")) >= 0)
        await tearDown(fixture)
    }

    @Test("Kept rows in a new order reload their parent alone")
    func reorderReloadsTheParent() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads

        await reload(fixture, tables: [TestFixtures.makeTableInfo(name: "customers"), TestFixtures.makeTableInfo(name: "orders")])

        #expect(fixture.outlineView.reloads == reloads)
        #expect(fixture.outlineView.reloadedParents == 1)
        let shown = try tableRows(fixture).map { fixture.outlineView.row(forItem: $0) }
        #expect(shown == shown.sorted())
        #expect(try tableNames(fixture) == ["customers", "orders"])
        await tearDown(fixture)
    }

    @Test("A rename in progress holds a row change until the edit ends")
    func renameHoldsRowChanges() async throws {
        let fixture = try await makeFixture()
        let ref = try #require(try tableRow(fixture, named: "orders").tableRef)
        fixture.coordinator.beginRename(.table(ref))
        #expect(fixture.coordinator.renameSession != nil)

        await reload(fixture, tables: [
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "customers"),
            TestFixtures.makeTableInfo(name: "invoices")
        ])

        #expect(fixture.outlineView.rowOperations == 0)
        #expect(fixture.coordinator.renameSession != nil)
        fixture.coordinator.endRename(commit: false)
        try await waitUntil { (try? tableNames(fixture).contains("invoices")) == true }
        #expect(fixture.outlineView.row(forItem: try tableRow(fixture, named: "invoices")) >= 0)
        await tearDown(fixture)
    }

    @Test("A row no rebuild has listed for a while is dropped, and one on screen stays")
    func unlistedNodesAreDropped() async throws {
        let fixture = try await makeFixture()
        let dropped = try tableRow(fixture, named: "customers").id
        let kept = try tableRow(fixture, named: "orders").id

        await reload(fixture, tables: [TestFixtures.makeTableInfo(name: "orders")])
        #expect(fixture.coordinator.nodeCache[dropped] != nil)
        for _ in 0..<16 { fixture.coordinator.refresh() }

        #expect(fixture.coordinator.nodeCache[dropped] == nil)
        #expect(fixture.coordinator.nodeCache[kept] != nil)
        await tearDown(fixture)
    }

    @Test("The generation moving alone is not a change to what the outline draws")
    func generationAloneChangesNothing() async throws {
        let fixture = try await makeFixture()
        let inputs = fixture.coordinator.currentRenderInputs()

        SchemaService.shared.bumpGeneration(fixture.connection.id)

        #expect(fixture.coordinator.currentRenderInputs() == inputs)
        await tearDown(fixture)
    }

    @Test("A schema a change overtook is a change, so an open row reads it again")
    func overtakenSchemaChangesTheInputs() async throws {
        let connection = TestFixtures.makeConnection(database: "", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.schemaTablesToReturn = ["sales": [TestFixtures.makeTableInfo(name: "orders", schema: "sales")]]
        let service = SchemaService()
        let scope = DatabaseScope(connectionId: connection.id, database: "", schema: nil)
        await service.loadSchemaObjects(schema: "sales", in: scope, driver: driver)
        func inputs() -> DatabaseTreeRenderInputs {
            DatabaseTreeRenderInputs(
                connectionId: connection.id,
                treeMetadata: .shared,
                schemaService: service,
                temporaryTables: .shared,
                sidebarState: nil,
                rootShape: .hierarchicalSchema,
                searchText: "",
                browsedDatabase: nil
            )
        }
        let current = inputs()
        #expect(current.schemaObjects["sales"]?.isCurrent == true)

        service.markLoadedSchemaObjectsStale(connectionId: connection.id)

        #expect(inputs() != current)
        #expect(inputs().schemaObjects["sales"]?.needsFetch == true)
    }

    @Test("Browsing another database is a change even when no list moved")
    func browsedDatabaseChangesTheInputs() async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        func inputs(_ database: String?) -> DatabaseTreeRenderInputs {
            DatabaseTreeRenderInputs(
                connectionId: connection.id,
                treeMetadata: .shared,
                schemaService: SchemaService(),
                temporaryTables: .shared,
                sidebarState: nil,
                rootShape: .flat,
                searchText: "",
                browsedDatabase: database
            )
        }

        #expect(inputs("shop") == inputs("shop"))
        #expect(inputs("shop") != inputs("archive"))
    }

    @Test("Typing in the filter field alone does not reload the outline")
    func searchTextWriteDoesNotReload() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads

        fixture.sidebarState.searchText = "ord"
        fixture.coordinator.reconcile()

        #expect(fixture.outlineView.reloads == reloads)
        await tearDown(fixture)
    }

    @Test("A recent table recorded for this connection adds its section without a reload")
    func recentTableAddsItsSection() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads

        fixture.sidebarState.recentTables = [RecentTableEntry(
            database: "shop", schema: nil, name: "orders", isView: false, objectType: nil, openedAt: Date()
        )]
        fixture.coordinator.reconcile()

        #expect(fixture.outlineView.reloads == reloads)
        let section = try #require(fixture.coordinator.resolvedChildren(of: nil).first { node in
            guard case .recentSection = node.kind else { return false }
            return true
        })
        #expect(fixture.outlineView.row(forItem: section) == 0)
        await tearDown(fixture)
    }

    @Test("An all-schema listing starting to load changes nothing the outline draws, and its rows landing do only under a search")
    func listingStartingToLoadIsNoChange() async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.allSchemaTablesToReturn = [TestFixtures.makeTableInfo(name: "timesheet", schema: "attendance")]
        driver.pausesNextAllSchemaTablesFetch = true
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let service = DatabaseTreeMetadataService.shared
        func inputs(searchText: String = "time") -> DatabaseTreeRenderInputs {
            DatabaseTreeRenderInputs(
                connectionId: connection.id,
                treeMetadata: service,
                schemaService: .shared,
                temporaryTables: .shared,
                sidebarState: nil,
                rootShape: .flat,
                searchText: searchText,
                browsedDatabase: "shop"
            )
        }
        let unread = inputs()
        let unsearched = inputs(searchText: "")

        let load = Task { await service.loadAllSchemaTables(connectionId: connection.id, database: "shop") }
        try await waitUntil {
            if case .loading = service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop") { return true }
            return false
        }
        #expect(inputs() == unread)

        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 }
        driver.resumeAllSchemaTablesFetch()
        await load.value
        #expect(service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value != nil)
        #expect(inputs() != unread)
        #expect(inputs(searchText: "") == unsearched)
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("The server's database list loading changes only the database tree's inputs")
    func databaseListLoadChangesOnlyTheTree() async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.databasesToReturn = ["shop", "blog"]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let service = DatabaseTreeMetadataService.shared
        func inputs(_ shape: SidebarRootShape) -> DatabaseTreeRenderInputs {
            DatabaseTreeRenderInputs(
                connectionId: connection.id,
                treeMetadata: service,
                schemaService: .shared,
                temporaryTables: .shared,
                sidebarState: nil,
                rootShape: shape,
                searchText: "",
                browsedDatabase: "shop"
            )
        }
        let flat = inputs(.flat)
        let hierarchical = inputs(.hierarchicalSchema)
        let tree = inputs(.databaseTree)

        await service.loadDatabases(connectionId: connection.id, databaseType: connection.type)

        #expect(service.databases(for: connection.id).count == 2)
        #expect(inputs(.flat) == flat)
        #expect(inputs(.hierarchicalSchema) == hierarchical)
        #expect(inputs(.databaseTree) != tree)
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A listing reads alike idle and loading, and apart once it loads or fails")
    func listingOutcomes() {
        typealias Listing = DatabaseTreeRenderInputs.Listing
        let rows = CatalogTableListing.Result(tables: [TestFixtures.makeTableInfo(name: "timesheet", schema: "attendance")], unlistedSchemas: [])

        #expect(Listing(.idle, covered: nil) == Listing(.loading, covered: nil))
        #expect(Listing(.loading, covered: nil).isUnread)
        #expect(Listing(.loading, covered: nil) != Listing(.loaded(rows), covered: .all))
        #expect(Listing(.loading, covered: nil) != Listing(.failed("timed out"), covered: nil))
        #expect(Listing(.loaded(rows), covered: .all) != Listing(.failed("timed out"), covered: nil))
        #expect(!Listing(.failed("timed out"), covered: nil).isUnread)
    }

    @Test("A reload over the same rows hands back the same row nodes")
    func unchangedRowsKeepTheirNodes() async throws {
        let fixture = try await makeFixture()
        let before = try tableRows(fixture)

        fixture.coordinator.refresh()
        let after = try tableRows(fixture)

        #expect(before.map { $0.id } == after.map { $0.id })
        #expect(SameRows(rows: before) == SameRows(rows: after))
        await tearDown(fixture)
    }
}
