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
}
