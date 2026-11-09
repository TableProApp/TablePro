import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

/// A table's detail lists load one kind at a time, the first time its group opens, and follow the
/// catalog the way partition lists do. PGlite keeps every read on the injected session driver.
@MainActor
struct DatabaseTreeTableDetailsServiceTests {
    private struct ReadFailed: Error {}

    private let service = DatabaseTreeMetadataService.shared

    private func connect() -> (DatabaseConnection, CatalogReadCountingDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.columnsByTable["orders"] = [
            TestFixtures.makeColumnInfo(name: "id", dataType: "integer"),
            TestFixtures.makeColumnInfo(name: "total", dataType: "numeric", isPrimaryKey: false),
        ]
        driver.indexesByTable["orders"] = [
            IndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true, type: "BTREE")
        ]
        driver.foreignKeysByTable["orders"] = [TestFixtures.makeForeignKeyInfo(name: "orders_user_fk")]
        driver.checksByTable["orders"] = [CheckConstraintInfo(name: "total_positive", expression: "total > 0")]
        driver.triggersByTable["orders"] = [
            TriggerInfo(name: "orders_audit", timing: "AFTER", event: "INSERT", statement: "")
        ]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func load(_ connection: DatabaseConnection, _ kind: TableDetailKind) async {
        await service.loadTableDetails(
            connectionId: connection.id, database: connection.database, schema: "public", table: "orders", kind: kind
        )
    }

    private func state(_ connection: DatabaseConnection, _ kind: TableDetailKind) -> MetadataLoadState<TableDetailList> {
        service.tableDetailsLoadState(
            connectionId: connection.id, database: connection.database, schema: "public", table: "orders", kind: kind
        )
    }

    private func needsFetch(_ connection: DatabaseConnection, _ kind: TableDetailKind) -> Bool {
        service.tableDetailsNeedFetch(
            connectionId: connection.id, database: connection.database, schema: "public", table: "orders", kind: kind
        )
    }

    private func columnNames(_ connection: DatabaseConnection) -> [String] {
        guard case .loaded(.columns(let columns)) = state(connection, .columns) else { return [] }
        return columns.map { $0.name }
    }

    @Test("Each kind is read once, by its own call, with two callers asking at once")
    func eachKindReadsOnce() async {
        let (connection, driver) = connect()

        for kind in TableDetailKind.allCases {
            async let first: Void = load(connection, kind)
            async let second: Void = load(connection, kind)
            _ = await (first, second)
        }

        #expect(driver.detailReads == [
            "columns:orders", "indexes:orders", "foreignKeys:orders", "checks:orders", "triggers:orders"
        ])
        #expect(columnNames(connection) == ["id", "total"])
        for kind in TableDetailKind.allCases {
            #expect(!needsFetch(connection, kind), "\(kind)")
        }
        await disconnect(connection)
    }

    @Test("Opening one group reads that kind alone and leaves the rest unread")
    func oneKindReadsAlone() async {
        let (connection, driver) = connect()

        await load(connection, .indexes)

        #expect(driver.detailReads == ["indexes:orders"])
        #expect(state(connection, .columns) == .idle)
        #expect(needsFetch(connection, .columns))
        #expect(!needsFetch(connection, .indexes))
        await disconnect(connection)
    }

    @Test("A failed first read shows its failure and is not asked for again until a change")
    func failedFirstRead() async {
        let (connection, driver) = connect()
        driver.detailError = ReadFailed()

        await load(connection, .checks)

        #expect(state(connection, .checks).erased.failureMessage != nil)
        #expect(!needsFetch(connection, .checks))
        await disconnect(connection)
    }

    @Test("Nothing reads while the session is not connected")
    func nothingReadsWhileNotConnected() async {
        let (connection, driver) = connect()
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connecting
        DatabaseManager.shared.injectSession(session, for: connection.id)

        #expect(!needsFetch(connection, .columns))
        await load(connection, .columns)

        #expect(state(connection, .columns) == .idle)
        #expect(driver.detailReads.isEmpty)
        await disconnect(connection)
    }

    private func change(_ connection: DatabaseConnection, _ kinds: SQLCatalogObjectKinds) async {
        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: kinds))
    }

    @Test("A table change marks every loaded list stale, keeps its rows, and the next ask reads it once")
    func tableChangeMarksListsStale() async {
        let (connection, driver) = connect()
        await load(connection, .columns)
        await load(connection, .triggers)
        driver.columnsByTable["orders"] = [TestFixtures.makeColumnInfo(name: "id", dataType: "bigint")]

        await change(connection, .tables)

        #expect(columnNames(connection) == ["id", "total"])
        #expect(needsFetch(connection, .columns))
        #expect(needsFetch(connection, .triggers))
        #expect(driver.detailReads == ["columns:orders", "triggers:orders"])

        async let first: Void = load(connection, .columns)
        async let second: Void = load(connection, .columns)
        _ = await (first, second)

        #expect(columnNames(connection) == ["id"])
        #expect(driver.detailReads == ["columns:orders", "triggers:orders", "columns:orders"])
        await disconnect(connection)
    }

    @Test("A trigger change marks trigger lists alone")
    func triggerChangeMarksTriggersAlone() async {
        let (connection, _) = connect()
        await load(connection, .columns)
        await load(connection, .triggers)

        await change(connection, .triggers)

        #expect(needsFetch(connection, .triggers))
        #expect(!needsFetch(connection, .columns))
        await disconnect(connection)
    }

    @Test("A failed refetch keeps the rows already on screen")
    func failedRefetchKeepsRows() async {
        let (connection, driver) = connect()
        await load(connection, .columns)
        await change(connection, .tables)
        driver.detailError = ReadFailed()

        await load(connection, .columns)

        #expect(columnNames(connection) == ["id", "total"])
        await disconnect(connection)
    }

    @Test("A reconnect keeps the rows and marks them stale, and a disconnect clears them")
    func reconnectKeepsAndDisconnectClears() async {
        let (connection, _) = connect()
        await load(connection, .columns)

        await service.handleReconnect(connectionId: connection.id)
        #expect(columnNames(connection) == ["id", "total"])
        #expect(needsFetch(connection, .columns))

        await service.handleDisconnect(connectionId: connection.id)
        #expect(state(connection, .columns) == .idle)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A read a disconnect overtakes commits nothing")
    func readOvertakenByDisconnectCommitsNothing() async {
        let (connection, driver) = connect()
        driver.pausesNextTableFetch = true
        var read: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onTableFetchPaused = { paused.resume() }
            read = Task { await load(connection, .columns) }
        }

        await service.handleDisconnect(connectionId: connection.id)
        driver.resumeTableFetch()
        await read?.value

        #expect(state(connection, .columns) == .idle)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("Dropping the lists clears every one, and a read the drop overtakes commits nothing")
    func dropClearsListsAndOvertakesARead() async {
        let (connection, driver) = connect()
        await load(connection, .indexes)
        driver.pausesNextTableFetch = true
        var read: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onTableFetchPaused = { paused.resume() }
            read = Task { await load(connection, .columns) }
        }

        service.dropTableDetails()
        driver.resumeTableFetch()
        await read?.value

        #expect(state(connection, .columns) == .idle)
        #expect(state(connection, .indexes) == .idle)
        #expect(needsFetch(connection, .columns))
        #expect(needsFetch(connection, .indexes))
        await disconnect(connection)
    }

    @Test("Refreshing a schema's tables reads a loaded list again and drops one that never loaded")
    func refreshRidesWithTheTables() async {
        let (connection, driver) = connect()
        await load(connection, .columns)
        driver.detailError = ReadFailed()
        await load(connection, .indexes)
        driver.detailError = nil
        driver.columnsByTable["orders"] = [TestFixtures.makeColumnInfo(name: "id", dataType: "bigint")]

        await service.refreshTableObjects(connectionId: connection.id, database: connection.database, schema: "public")

        #expect(columnNames(connection) == ["id"])
        #expect(state(connection, .indexes) == .idle)
        #expect(needsFetch(connection, .indexes))
        await disconnect(connection)
    }
}
