import AppKit
import Foundation
import os
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

/// A table's detail groups in a real outline: what each group lists, when it reads, and what the
/// window remembers. PGlite keeps every read on the injected session driver.
@MainActor
struct DatabaseTreeTableDetailOutlineTests {
    private struct ReadFailed: Error {}

    private struct Fixture {
        let connection: DatabaseConnection
        let driver: CatalogReadCountingDriver
        let coordinator: DatabaseTreeOutlineCoordinator
        let windowState: WindowSidebarState
        let outlineView: NSOutlineView
        let scrollView: NSScrollView
    }

    private let service = DatabaseTreeMetadataService.shared

    private func makeFixture(showsTableDetails: Bool = true, showsPartitions: Bool = true) throws -> Fixture {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.columnsByTable["orders"] = [
            TestFixtures.makeColumnInfo(name: "id", dataType: "integer"),
            TestFixtures.makeColumnInfo(name: "total", dataType: "numeric", isPrimaryKey: false),
        ]
        driver.foreignKeysByTable["orders"] = [
            TestFixtures.makeForeignKeyInfo(
                name: "orders_customer_fk", column: "customer_id", referencedTable: "customers", referencedColumn: "id"
            ),
            TestFixtures.makeForeignKeyInfo(
                name: "orders_customer_fk", column: "customer_region", referencedTable: "customers", referencedColumn: "region"
            ),
        ]
        driver.triggersByTable["orders"] = [
            TriggerInfo(name: "orders_audit", timing: "AFTER", event: "INSERT", statement: "")
        ]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: DatabaseTreeNSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TableDetailColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let windowState = WindowSidebarState()
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .pglite
        coordinator.windowState = windowState
        coordinator.showsTableDetails = showsTableDetails
        coordinator.showsPartitions = showsPartitions
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        return Fixture(
            connection: connection,
            driver: driver,
            coordinator: coordinator,
            windowState: windowState,
            outlineView: outlineView,
            scrollView: scrollView
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        await service.handleDisconnect(connectionId: fixture.connection.id)
        DatabaseManager.shared.removeSession(for: fixture.connection.id)
        _ = fixture.scrollView
    }

    private func orders(_ fixture: Fixture, type: TableInfo.TableType = .table) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: fixture.connection.database,
            schema: "public",
            table: TableInfo(name: "orders", type: type, rowCount: nil, schema: "public")
        )
    }

    private func group(
        _ fixture: Fixture, _ kind: TableDetailGroupKind, type: TableInfo.TableType = .table
    ) -> DatabaseTreeTableDetailGroupRef {
        DatabaseTreeTableDetailGroupRef(table: orders(fixture, type: type), kind: kind)
    }

    private func node(_ fixture: Fixture, _ group: DatabaseTreeTableDetailGroupRef) -> DatabaseTreeNode {
        fixture.coordinator.node(id: DatabaseTreeNode.tableDetailGroupId(group), kind: .tableDetailGroup(group))
    }

    private func load(_ fixture: Fixture, _ kind: TableDetailKind) async {
        await service.loadTableDetails(
            connectionId: fixture.connection.id, database: fixture.connection.database,
            schema: "public", table: "orders", kind: kind
        )
    }

    private func detailState(_ fixture: Fixture, _ kind: TableDetailKind) -> MetadataLoadState<TableDetailList> {
        service.tableDetailsLoadState(
            connectionId: fixture.connection.id, database: fixture.connection.database,
            schema: "public", table: "orders", kind: kind
        )
    }

    /// What a reload after a landed list builds.
    private func rebuiltChildren(_ fixture: Fixture, of node: DatabaseTreeNode) -> [DatabaseTreeNode] {
        fixture.coordinator.childrenCache.removeValue(forKey: node.id)
        return fixture.coordinator.resolvedChildren(of: node)
    }

    private func showAtRoot(_ fixture: Fixture, _ nodes: [DatabaseTreeNode]) {
        fixture.coordinator.childrenCache = ["": nodes]
        fixture.outlineView.reloadData()
    }

    @Test("A Columns group shows a loading row, then one row per column and its count")
    func columnsGroupListsColumns() async throws {
        let fixture = try makeFixture()
        let columns = group(fixture, .columns)
        let groupNode = node(fixture, columns)
        let groupId = DatabaseTreeNode.tableDetailGroupId(columns)
        let loadingIds = fixture.coordinator.resolvedChildren(of: groupNode).map { $0.id }

        #expect(loadingIds == [DatabaseTreeNode.statusId(parentId: groupId, status: .loading)])
        #expect(fixture.coordinator.tableDetailCount(columns) == nil)

        await load(fixture, .columns)

        let names = rebuiltChildren(fixture, of: groupNode).compactMap { row -> String? in
            guard case .tableDetail(let detail) = row.kind else { return nil }
            return detail.item.name
        }
        #expect(names == ["id", "total"])
        #expect(fixture.coordinator.tableDetailCount(columns) == 2)
        await tearDown(fixture)
    }

    @Test("A two-column foreign key is one row, and the group counts it once")
    func foreignKeyGroupCountsConstraints() async throws {
        let fixture = try makeFixture()
        let keys = group(fixture, .foreignKeys)

        await load(fixture, .foreignKeys)

        #expect(rebuiltChildren(fixture, of: node(fixture, keys)).count == 1)
        #expect(fixture.coordinator.tableDetailCount(keys) == 1)
        await tearDown(fixture)
    }

    @Test("A trigger under its table is a trigger row, with an id apart from its schema's listing")
    func triggerRowsUnderTheirTable() async throws {
        let fixture = try makeFixture()

        await load(fixture, .triggers)

        let row = try #require(rebuiltChildren(fixture, of: node(fixture, group(fixture, .triggers))).first)
        guard case .trigger(let ref) = row.kind else {
            Issue.record("A trigger under its table is not a trigger row")
            return
        }
        #expect(ref.listedUnderTable)
        #expect(ref.trigger.table == "orders")
        #expect(row.id != DatabaseTreeNode.triggerId(ref))
        await tearDown(fixture)
    }

    @Test("Two checks that share a name are two rows")
    func sameNamedChecksAreTwoRows() async throws {
        let fixture = try makeFixture()
        fixture.driver.checksByTable["orders"] = [
            CheckConstraintInfo(name: "", expression: "total > 0"),
            CheckConstraintInfo(name: "", expression: "total < 1000"),
        ]

        await load(fixture, .checks)

        let rows = rebuiltChildren(fixture, of: node(fixture, group(fixture, .checks)))
        let ids = Set(rows.map { $0.id })
        #expect(rows.count == 2)
        #expect(ids.count == 2)
        #expect(rows.first !== rows.last)
        await tearDown(fixture)
    }

    @Test("A Partitions group lists the table's partitions, under a loading row of its own")
    func partitionsGroupListsPartitions() async throws {
        let fixture = try makeFixture()
        let partitions = group(fixture, .partitions, type: .partitionedTable)
        let groupId = DatabaseTreeNode.tableDetailGroupId(partitions)

        let ids = fixture.coordinator.resolvedChildren(of: node(fixture, partitions)).map { $0.id }

        #expect(ids == [DatabaseTreeNode.statusId(parentId: groupId, status: .loading)])
        await tearDown(fixture)
    }

    @Test("An empty list shows the empty row, and a failed read its error under its own group")
    func emptyAndFailedListsShowTheirStatus() async throws {
        let fixture = try makeFixture()
        let indexes = group(fixture, .indexes)
        let checks = group(fixture, .checks)

        await load(fixture, .indexes)
        fixture.driver.detailError = ReadFailed()
        await load(fixture, .checks)

        let indexIds = rebuiltChildren(fixture, of: node(fixture, indexes)).map { $0.id }
        let checkRows = rebuiltChildren(fixture, of: node(fixture, checks))
        let indexesId = DatabaseTreeNode.tableDetailGroupId(indexes)
        #expect(indexIds == [DatabaseTreeNode.statusId(parentId: indexesId, status: .empty)])
        #expect(fixture.coordinator.tableDetailCount(indexes) == 0)
        guard checkRows.count == 1, case .status(.error) = checkRows[0].kind else {
            Issue.record("A failed read does not show its error row")
            await tearDown(fixture)
            return
        }
        #expect(fixture.coordinator.resolvedChildren(of: node(fixture, group(fixture, .columns))).count == 1)
        await tearDown(fixture)
    }

    @Test("Opening a group reads its own kind alone, and the window records it open and closed")
    func openingAGroupReadsItsKind() async throws {
        let fixture = try makeFixture()
        let indexes = group(fixture, .indexes)
        let groupNode = node(fixture, indexes)
        showAtRoot(fixture, [groupNode])

        fixture.outlineView.expandItem(groupNode)
        try await waitUntil { detailState(fixture, .indexes).value != nil }

        #expect(fixture.driver.detailReads == ["indexes:orders"])
        #expect(fixture.windowState.expandedTreeTableDetailGroups == [indexes.expansionKey])

        fixture.outlineView.collapseItem(groupNode)
        #expect(fixture.windowState.expandedTreeTableDetailGroups.isEmpty)
        await tearDown(fixture)
    }

    @Test("A group whose read failed reads again when the user opens it again")
    func reopeningAFailedGroupRetries() async throws {
        let fixture = try makeFixture()
        let groupNode = node(fixture, group(fixture, .columns))
        showAtRoot(fixture, [groupNode])
        fixture.driver.detailError = ReadFailed()

        fixture.outlineView.expandItem(groupNode)
        try await waitUntil { detailState(fixture, .columns).erased.failureMessage != nil }

        fixture.driver.detailError = nil
        fixture.outlineView.collapseItem(groupNode)
        fixture.outlineView.expandItem(groupNode)
        try await waitUntil { detailState(fixture, .columns).value != nil }

        #expect(fixture.driver.detailReads == ["columns:orders", "columns:orders"])
        await tearDown(fixture)
    }

    private func tableNode(_ fixture: Fixture, type: TableInfo.TableType = .table) -> DatabaseTreeNode {
        let ref = orders(fixture, type: type)
        return fixture.coordinator.node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
    }

    private func groupKinds(_ fixture: Fixture, of node: DatabaseTreeNode) -> [TableDetailGroupKind] {
        fixture.coordinator.resolvedChildren(of: node).compactMap { child in
            guard case .tableDetailGroup(let group) = child.kind else { return nil }
            return group.kind
        }
    }

    private func isExpandable(_ fixture: Fixture, _ node: DatabaseTreeNode) -> Bool {
        fixture.coordinator.outlineView(fixture.outlineView, isItemExpandable: node)
    }

    /// What `refresh()` does for these rows: drop every built child, reload, and put the saved
    /// disclosure back. The root is the flat shape's Tables section with one table under it.
    private func reloadFlat(_ fixture: Fixture, table: DatabaseTreeNode) {
        let section = fixture.coordinator.node(
            id: DatabaseTreeNode.objectKindSectionId(.table), kind: .objectKindSection(.table)
        )
        fixture.coordinator.childrenCache = ["": [section], section.id: [table]]
        fixture.outlineView.reloadData()
        fixture.coordinator.applyDesiredExpansion()
    }

    @Test("With Table Details off, a plain table has no triangle and a partitioned one lists partitions as before")
    func detailsOffKeepsTodaysTree() async throws {
        let fixture = try makeFixture(showsTableDetails: false)
        let partitionedId = DatabaseTreeNode.tableId(orders(fixture, type: .partitionedTable))
        let partitioned = tableNode(fixture, type: .partitionedTable)
        let childIds = fixture.coordinator.resolvedChildren(of: partitioned).map { $0.id }

        #expect(!isExpandable(fixture, tableNode(fixture)))
        #expect(isExpandable(fixture, partitioned))
        #expect(childIds == [DatabaseTreeNode.statusId(parentId: partitionedId, status: .loading)])
        await tearDown(fixture)
    }

    @Test("With Table Details on, a table lists the groups its engine and relation type support")
    func detailsOnListsGroups() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)

        #expect(isExpandable(fixture, table))
        #expect(groupKinds(fixture, of: table) == [.columns, .indexes, .foreignKeys, .checks, .triggers])
        #expect(groupKinds(fixture, of: tableNode(fixture, type: .view)) == [.columns])
        #expect(groupKinds(fixture, of: tableNode(fixture, type: .materializedView)) == [.columns, .indexes])
        #expect(!isExpandable(fixture, tableNode(fixture, type: .sequence)))
        await tearDown(fixture)
    }

    @Test("A partitioned table's partitions move into a last Partitions group, shown only while Partitions is on")
    func partitionsGroupFollowsItsOption() async throws {
        let shown = try makeFixture()
        let hidden = try makeFixture(showsPartitions: false)
        let hiddenTable = tableNode(hidden, type: .partitionedTable)

        #expect(groupKinds(shown, of: tableNode(shown, type: .partitionedTable)).last == .partitions)
        #expect(isExpandable(hidden, hiddenTable))
        #expect(!groupKinds(hidden, of: hiddenTable).contains(.partitions))
        await tearDown(shown)
        await tearDown(hidden)
    }

    @Test("Opening a table reads nothing until one of its groups opens")
    func openingATableReadsNothing() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture, type: .partitionedTable)
        showAtRoot(fixture, [table])

        fixture.outlineView.expandItem(table)
        let columns = try #require(fixture.coordinator.resolvedChildren(of: table).first)
        fixture.outlineView.expandItem(columns)
        try await waitUntil { detailState(fixture, .columns).value != nil }

        let partitions = service.partitionsLoadState(
            connectionId: fixture.connection.id, database: fixture.connection.database, schema: "public", table: "orders"
        )
        #expect(fixture.driver.detailReads == ["columns:orders"])
        #expect(partitions.erased == .idle)
        await tearDown(fixture)
    }

    /// The flat shape's Tables section with one table under it, before any restore pass runs.
    private func showFlat(_ fixture: Fixture, table: DatabaseTreeNode) -> DatabaseTreeNode {
        let section = fixture.coordinator.node(
            id: DatabaseTreeNode.objectKindSectionId(.table), kind: .objectKindSection(.table)
        )
        fixture.coordinator.childrenCache = ["": [section], section.id: [table]]
        fixture.outlineView.reloadData()
        return section
    }

    /// `expandItem(_:expandChildren:)` is what an Option-click on a disclosure triangle calls.
    @Test("An Option-click on the Tables section opens no table, so no group reads or is saved")
    func optionClickOpensNoTable() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)
        let section = showFlat(fixture, table: table)

        fixture.outlineView.expandItem(section, expandChildren: true)
        let openGroups = fixture.coordinator.resolvedChildren(of: table).filter { group in
            fixture.outlineView.isItemExpanded(group)
        }

        #expect(fixture.outlineView.isItemExpanded(section))
        #expect(!fixture.outlineView.isItemExpanded(table))
        #expect(openGroups.isEmpty)
        #expect(fixture.windowState.expandedTreeTables.isEmpty)
        #expect(fixture.windowState.expandedTreeTableDetailGroups.isEmpty)
        #expect(fixture.driver.detailReads.isEmpty)
        await tearDown(fixture)
    }

    @Test("An Option-click on a table opens that table alone, and a group still opens by its own click")
    func optionClickOnATableOpensItAlone() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)
        showAtRoot(fixture, [table])

        fixture.outlineView.expandItem(table, expandChildren: true)
        let groups = fixture.coordinator.resolvedChildren(of: table)
        let openGroups = groups.filter { group in fixture.outlineView.isItemExpanded(group) }

        #expect(fixture.outlineView.isItemExpanded(table))
        #expect(openGroups.isEmpty)
        #expect(fixture.windowState.expandedTreeTables == [DatabaseTableKey(orders(fixture))])
        #expect(fixture.windowState.expandedTreeTableDetailGroups.isEmpty)

        let columns = try #require(groups.first)
        fixture.outlineView.expandItem(columns)
        try await waitUntil { detailState(fixture, .columns).value != nil }

        #expect(fixture.outlineView.isItemExpanded(columns))
        #expect(fixture.driver.detailReads == ["columns:orders"])
        await tearDown(fixture)
    }

    @Test("With Table Details off, an Option-click still opens a partitioned table and reads its partitions")
    func optionClickKeepsPartitionsWhenDetailsAreOff() async throws {
        let fixture = try makeFixture(showsTableDetails: false)
        let ref = orders(fixture, type: .partitionedTable)
        let table = tableNode(fixture, type: .partitionedTable)
        let section = showFlat(fixture, table: table)

        fixture.outlineView.expandItem(section, expandChildren: true)
        try await waitUntil { fixture.driver.reads.contains("partitions:orders") }

        #expect(fixture.outlineView.isItemExpanded(table))
        #expect(fixture.windowState.expandedTreeTables == [DatabaseTableKey(ref)])
        await tearDown(fixture)
    }

    @Test("An open table and group come back after a reload, and the group reads its list")
    func openGroupsAreRestored() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)
        let columns = group(fixture, .columns)
        fixture.windowState.expandedTreeTables = [DatabaseTableKey(orders(fixture))]
        fixture.windowState.expandedTreeTableDetailGroups = [columns.expansionKey]

        reloadFlat(fixture, table: table)

        #expect(fixture.outlineView.isItemExpanded(table))
        #expect(fixture.outlineView.isItemExpanded(node(fixture, columns)))
        try await waitUntil { detailState(fixture, .columns).value != nil }
        #expect(fixture.driver.detailReads == ["columns:orders"])
        await tearDown(fixture)
    }

    private func detailNames(_ rows: [DatabaseTreeNode]) -> [String] {
        rows.compactMap { row -> String? in
            guard case .tableDetail(let detail) = row.kind else { return nil }
            return detail.item.name
        }
    }

    @Test("A catalog change reads an open group again on the restore pass, and its rows stay until the read lands")
    func catalogChangeRereadsAnOpenGroupKeepingItsRows() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)
        let columns = group(fixture, .columns)
        let groupNode = node(fixture, columns)
        fixture.windowState.expandedTreeTables = [DatabaseTableKey(orders(fixture))]
        fixture.windowState.expandedTreeTableDetailGroups = [columns.expansionKey]
        reloadFlat(fixture, table: table)
        try await waitUntil { detailState(fixture, .columns).value != nil }
        fixture.driver.columnsByTable["orders"] = [TestFixtures.makeColumnInfo(name: "id", dataType: "bigint")]

        await service.refreshCatalog(for: CatalogChange(connectionId: fixture.connection.id, kinds: .tables))
        let paused = OSAllocatedUnfairLock(initialState: false)
        fixture.driver.onTableFetchPaused = { paused.withLock { $0 = true } }
        fixture.driver.pausesNextTableFetch = true
        reloadFlat(fixture, table: table)
        try await waitUntil { paused.withLock { $0 } }

        #expect(detailNames(rebuiltChildren(fixture, of: groupNode)) == ["id", "total"])

        fixture.driver.resumeTableFetch()
        try await waitUntil { detailNames(rebuiltChildren(fixture, of: groupNode)) == ["id"] }
        #expect(fixture.outlineView.isItemExpanded(groupNode))
        #expect(fixture.driver.detailReads == ["columns:orders", "columns:orders"])
        await tearDown(fixture)
    }

    @Test("While a search runs, an open group still reads a list a reconnect overtook")
    func openGroupRereadsDuringSearch() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)
        let columns = group(fixture, .columns)
        fixture.windowState.expandedTreeTables = [DatabaseTableKey(orders(fixture))]
        fixture.windowState.expandedTreeTableDetailGroups = [columns.expansionKey]
        reloadFlat(fixture, table: table)
        try await waitUntil { detailState(fixture, .columns).value != nil }

        fixture.coordinator.searchText = "orders"
        await service.handleReconnect(connectionId: fixture.connection.id)
        reloadFlat(fixture, table: table)
        try await waitUntil { fixture.driver.detailReads.count == 2 }

        #expect(fixture.outlineView.isItemExpanded(table))
        #expect(fixture.outlineView.isItemExpanded(node(fixture, columns)))
        #expect(fixture.driver.detailReads == ["columns:orders", "columns:orders"])
        await tearDown(fixture)
    }

    @Test("A search opens no table the window recorded open, so it reads no group")
    func searchOpensNoRecordedTable() async throws {
        let fixture = try makeFixture()
        let table = tableNode(fixture)
        let columns = group(fixture, .columns)
        fixture.windowState.expandedTreeTables = [DatabaseTableKey(orders(fixture))]
        fixture.windowState.expandedTreeTableDetailGroups = [columns.expansionKey]
        fixture.coordinator.searchText = "orders"

        reloadFlat(fixture, table: table)

        #expect(!fixture.outlineView.isItemExpanded(table))
        #expect(!fixture.outlineView.isItemExpanded(node(fixture, columns)))
        #expect(detailState(fixture, .columns) == .idle)
        await tearDown(fixture)
    }

    @Test("A detail list landing changes what the outline draws, and another connection's does not")
    func landingListMovesTheRenderInputs() async throws {
        let fixture = try makeFixture()
        let other = try makeFixture()
        let before = fixture.coordinator.currentRenderInputs()

        await load(other, .columns)
        #expect(fixture.coordinator.currentRenderInputs() == before)

        await load(fixture, .columns)
        #expect(fixture.coordinator.currentRenderInputs() != before)
        await tearDown(fixture)
        await tearDown(other)
    }

    @Test("Refreshing a schema in the hierarchical layout reads its tables' loaded detail lists again")
    func hierarchicalRefreshRereadsDetailLists() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.activeDatabase = fixture.connection.database
        await load(fixture, .columns)
        fixture.driver.columnsByTable["orders"] = [TestFixtures.makeColumnInfo(name: "id", dataType: "bigint")]

        fixture.coordinator.reloadHierarchicalSchemaObjects("public")
        try await waitUntil { fixture.driver.detailReads.count == 2 }
        try await waitUntil {
            guard case .loaded(.columns(let columns)) = detailState(fixture, .columns) else { return false }
            return columns.map { $0.name } == ["id"]
        }

        #expect(fixture.driver.detailReads == ["columns:orders", "columns:orders"])
        await tearDown(fixture)
    }

    @Test("Turning Table Details off drops the lists it loaded, so a refresh reads none of them")
    func turningDetailsOffDropsTheLists() async throws {
        let fixture = try makeFixture()
        await load(fixture, .columns)
        await load(fixture, .triggers)

        fixture.coordinator.showsTableDetails = false
        await service.refreshTableObjects(
            connectionId: fixture.connection.id, database: fixture.connection.database, schema: "public"
        )

        #expect(fixture.driver.detailReads == ["columns:orders", "triggers:orders"])
        #expect(detailState(fixture, .columns) == .idle)
        #expect(detailState(fixture, .triggers) == .idle)
        await tearDown(fixture)
    }

    @Test("Turning Table Details off shows the partitions again, and turning it on brings the open group back")
    func togglingKeepsTheOpenGroup() async throws {
        let fixture = try makeFixture()
        let ref = orders(fixture, type: .partitionedTable)
        let table = tableNode(fixture, type: .partitionedTable)
        let columns = group(fixture, .columns, type: .partitionedTable)
        fixture.windowState.expandedTreeTables = [DatabaseTableKey(ref)]
        fixture.windowState.expandedTreeTableDetailGroups = [columns.expansionKey]
        reloadFlat(fixture, table: table)
        #expect(fixture.outlineView.isItemExpanded(node(fixture, columns)))

        fixture.coordinator.showsTableDetails = false
        reloadFlat(fixture, table: table)
        let plainIds = fixture.coordinator.resolvedChildren(of: table).map { $0.id }
        #expect(plainIds == [DatabaseTreeNode.statusId(parentId: DatabaseTreeNode.tableId(ref), status: .loading)])
        #expect(fixture.windowState.expandedTreeTableDetailGroups == [columns.expansionKey])

        fixture.coordinator.showsTableDetails = true
        reloadFlat(fixture, table: table)
        #expect(fixture.outlineView.isItemExpanded(node(fixture, columns)))
        await tearDown(fixture)
    }
}
