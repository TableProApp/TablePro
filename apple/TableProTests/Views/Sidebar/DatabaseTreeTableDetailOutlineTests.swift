import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
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

    private func makeFixture() throws -> Fixture {
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
            outlineView: NSOutlineView(),
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
}
