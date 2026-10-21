//
//  ShortcutsActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private actor RecordingGate: ExecutionGate {
    private(set) var requests: [OperationRequest] = []

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        requests.append(request)
        return .authorized(
            OperationReceipt(
                connectionId: request.connectionId,
                kind: request.kind,
                effectiveWrite: true,
                grantedAt: Date(),
                token: UUID()
            )
        )
    }
}

private actor RecordingHistory: QueryHistoryRecording {
    private(set) var requests: [QueryHistoryRecordRequest] = []

    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        requests.append(request)
        return true
    }
}

private final class InsertRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let columns: [PluginColumnInfo]
    let transactionState: PluginSessionTransactionState
    let supportsTransactions: Bool
    private let failingInsert: Int?
    private var inserts = 0

    init(
        columns: [PluginColumnInfo],
        transactionState: PluginSessionTransactionState = .idle,
        supportsTransactions: Bool = true,
        failingInsert: Int? = nil
    ) {
        self.columns = columns
        self.transactionState = transactionState
        self.supportsTransactions = supportsTransactions
        self.failingInsert = failingInsert
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { transactionState }

    var received: [String] {
        lock.withLock { log }
    }

    private func record(_ query: String) -> PluginQueryResult {
        lock.withLock { log.append(query) }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 1, executionTime: 0)
    }

    func execute(query: String) async throws -> PluginQueryResult { record(query) }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let attempt = lock.withLock { () -> Int in
            inserts += 1
            return inserts
        }
        if attempt == failingInsert {
            throw DatabaseError.queryFailed("duplicate key")
        }
        return record(query)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { columns }

    func switchDatabase(to database: String) async throws {}
}

extension GlobalStateSuites {
    @MainActor
    struct ShortcutsActionTests {
        private static func save(_ connection: DatabaseConnection) -> [DatabaseConnection] {
            let saved = ConnectionStorage.shared.loadConnections()
            ConnectionStorage.shared.saveConnections(saved + [connection])
            return saved
        }

        private static func restore(_ saved: [DatabaseConnection], removing connection: DatabaseConnection) {
            DatabaseManager.shared.removeSession(for: connection.id)
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            ConnectionStorage.shared.saveConnections(saved)
        }

        private static func connection(_ access: ExternalAccessLevel, type: DatabaseType) -> DatabaseConnection {
            var connection = DatabaseConnection(name: "Shop", database: "shop", type: type)
            connection.externalAccess = access
            return connection
        }

        private static func injectQueryDriver(for connection: DatabaseConnection) -> ScriptAnsweringDriver {
            let driver = ScriptAnsweringDriver(connection: connection, sendsBatchesWhole: false)
            var session = ConnectionSession(connection: connection)
            session.driver = driver
            DatabaseManager.shared.injectSession(session, for: connection.id)
            return driver
        }

        @Test("Run Query hands back the rows and files the statement under Shortcuts, asked as Shortcuts")
        func runQueryOnAListedConnection() async throws {
            let connection = Self.connection(.readOnly, type: .postgresql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let driver = Self.injectQueryDriver(for: connection)
            let gate = RecordingGate()
            let history = RecordingHistory()

            let outcome = try await ShortcutsQuery.run(
                sql: "SELECT count(*) FROM orders",
                connectionId: connection.id,
                namespace: nil,
                rowLimit: nil,
                history: history,
                gate: gate
            )

            #expect(driver.sentStatements.count == 1)
            #expect(QueryResultFiles.firstValue(rows: outcome.primary.rows) == "1")
            #expect(await gate.requests.map(\.caller) == [.shortcuts])
            #expect(await history.requests.map(\.source) == [.shortcuts])
            #expect(await history.requests.map(\.query) == ["SELECT count(*) FROM orders"])
        }

        @Test("Run Query on a Blocked connection fails with the reason and reaches nothing")
        func runQueryOnABlockedConnection() async throws {
            let connection = Self.connection(.blocked, type: .postgresql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let driver = Self.injectQueryDriver(for: connection)
            let gate = RecordingGate()
            let history = RecordingHistory()

            await #expect(throws: ShortcutsActionError(message: "External access is disabled for this connection")) {
                try await ShortcutsQuery.run(
                    sql: "SELECT count(*) FROM orders",
                    connectionId: connection.id,
                    namespace: nil,
                    rowLimit: nil,
                    history: history,
                    gate: gate
                )
            }
            #expect(driver.sentStatements.isEmpty)
            #expect(await gate.requests.isEmpty)
            #expect(await history.requests.isEmpty)
        }

        @Test("Run Query on a deleted connection says it no longer exists")
        func runQueryOnADeletedConnection() async throws {
            await #expect(throws: ShortcutsActionError(message: "That connection no longer exists in TablePro.")) {
                try await ShortcutsQuery.run(
                    sql: "SELECT 1",
                    connectionId: UUID(),
                    namespace: nil,
                    rowLimit: nil,
                    history: RecordingHistory(),
                    gate: RecordingGate()
                )
            }
        }

        @Test("A write from Run Query on a Read Only connection is refused before the gate is asked")
        func runQueryWriteOnReadOnly() async throws {
            let connection = Self.connection(.readOnly, type: .postgresql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let driver = Self.injectQueryDriver(for: connection)
            let gate = RecordingGate()

            await #expect(throws: ShortcutsActionError(message: "This connection is read only for external clients.")) {
                try await ShortcutsQuery.run(
                    sql: "DELETE FROM orders WHERE id = 1",
                    connectionId: connection.id,
                    namespace: nil,
                    rowLimit: nil,
                    history: RecordingHistory(),
                    gate: gate
                )
            }
            #expect(driver.sentStatements.isEmpty)
            #expect(await gate.requests.isEmpty)
        }

        @Test("Add Rows on a Read Only connection is refused before anything connects")
        func addRowsOnReadOnly() async throws {
            let connection = Self.connection(.readOnly, type: .mysql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let gate = RecordingGate()

            await #expect(throws: ShortcutsActionError(message: "This connection is read only for external clients.")) {
                try await ShortcutsRowWriter.insert(
                    ShortcutsRowWriter.Request(
                        rows: [PayloadRow(values: ["name": .text("Ada")])],
                        table: "orders",
                        connectionId: connection.id,
                        namespace: nil
                    ),
                    history: RecordingHistory(),
                    gate: gate
                )
            }
            #expect(DatabaseManager.shared.activeSessions[connection.id] == nil)
            #expect(await gate.requests.isEmpty)
        }

        private static let orderColumns = [
            PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true, extra: "auto_increment"),
            PluginColumnInfo(name: "name", dataType: "varchar(64)")
        ]

        // The session driver sees nothing in these cases; the pooled one stands for the connection of the action's own.
        private static func injectPooled(
            _ pooled: InsertRecordingDriver,
            for connection: DatabaseConnection
        ) async throws -> InsertRecordingDriver {
            let sessionDriver = InsertRecordingDriver(columns: orderColumns)
            var session = ConnectionSession(
                connection: connection,
                driver: PluginDriverAdapter(connection: connection, pluginDriver: sessionDriver)
            )
            session.browseDatabase = "shop"
            DatabaseManager.shared.injectSession(session, for: connection.id)
            let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pooled)
            try await adapter.connect()
            MetadataConnectionPool.shared.injectEntry(
                adapter,
                scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
            )
            return sessionDriver
        }

        private static func addTwoRows(to connection: DatabaseConnection) async throws -> Int {
            try await ShortcutsRowWriter.insert(
                ShortcutsRowWriter.Request(
                    rows: try RowPayload.parseJSON(#"[{"name":"Ada"},{"name":"Grace"}]"#),
                    table: "orders",
                    connectionId: connection.id,
                    namespace: nil
                ),
                history: RecordingHistory(),
                gate: RecordingGate()
            )
        }

        @Test("Add Rows inserts every row in one transaction of its own and files it under Shortcuts")
        func addRowsInOneTransaction() async throws {
            let connection = Self.connection(.readWrite, type: .mysql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let pooled = InsertRecordingDriver(columns: Self.orderColumns)
            let sessionDriver = try await Self.injectPooled(pooled, for: connection)
            let gate = RecordingGate()
            let history = RecordingHistory()
            let rows = try RowPayload.parseJSON(#"[{"id":"","name":"Ada"},{"name":"Grace"}]"#)

            let inserted = try await ShortcutsRowWriter.insert(
                ShortcutsRowWriter.Request(rows: rows, table: "orders", connectionId: connection.id, namespace: nil),
                history: history,
                gate: gate
            )

            let insert = "INSERT INTO `orders` (`name`) VALUES (?)"
            #expect(inserted == 2)
            #expect(pooled.received == ["BEGIN", insert, insert, "COMMIT"])
            #expect(sessionDriver.received.isEmpty)
            #expect(await gate.requests.map(\.caller) == [.shortcuts])
            let approved = try #require(await gate.requests.first?.sql)
            #expect(approved.contains("'Ada'"))
            #expect(approved.contains("'Grace'"))
            #expect(await history.requests.map(\.source) == [.shortcuts])
            #expect(await history.requests.map(\.query) == [insert])
            #expect(await history.requests.map(\.rowCount) == [2])
        }

        @Test("Add Rows will not nest inside a transaction a startup command left open on its own connection")
        func addRowsRefusesAStartupTransaction() async throws {
            let connection = Self.connection(.readWrite, type: .mysql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let pooled = InsertRecordingDriver(columns: Self.orderColumns, transactionState: .inTransaction)
            _ = try await Self.injectPooled(pooled, for: connection)

            await #expect(throws: ShortcutsActionError(
                message: "This connection's startup commands leave a transaction open, so rows added from Shortcuts could not be committed."
            )) {
                try await Self.addTwoRows(to: connection)
            }
            #expect(pooled.received.isEmpty)
        }

        @Test("An engine without transactions says how many rows were already written when a later one fails")
        func addRowsReportsWhatAnEngineWithoutTransactionsKept() async throws {
            let connection = Self.connection(.readWrite, type: .mysql)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let pooled = InsertRecordingDriver(columns: Self.orderColumns, supportsTransactions: false, failingInsert: 2)
            _ = try await Self.injectPooled(pooled, for: connection)

            await #expect(throws: ShortcutsActionError(
                message: "1 of 2 statements were already written, and MySQL cannot roll them back. duplicate key"
            )) {
                try await Self.addTwoRows(to: connection)
            }
            #expect(pooled.received == ["INSERT INTO `orders` (`name`) VALUES (?)"])
        }

        @Test("Add Rows will not join a transaction the user left open on the one connection an engine allows")
        func addRowsRefusesTheUsersOpenTransaction() async throws {
            let connection = Self.connection(.readWrite, type: .duckdb)
            let saved = Self.save(connection)
            defer { Self.restore(saved, removing: connection) }
            let driver = InsertRecordingDriver(
                columns: [PluginColumnInfo(name: "name", dataType: "VARCHAR")],
                transactionState: .inTransaction
            )
            let session = ConnectionSession(
                connection: connection,
                driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
            )
            DatabaseManager.shared.injectSession(session, for: connection.id)

            await #expect(throws: ShortcutsActionError(
                message: "A transaction is open on this connection. Commit or roll it back in TablePro, then run the shortcut again."
            )) {
                try await ShortcutsRowWriter.insert(
                    ShortcutsRowWriter.Request(
                        rows: [PayloadRow(values: ["name": .text("Ada")])],
                        table: "orders",
                        connectionId: connection.id,
                        namespace: nil
                    ),
                    history: RecordingHistory(),
                    gate: RecordingGate()
                )
            }
            #expect(driver.received.isEmpty)
        }
    }
}
