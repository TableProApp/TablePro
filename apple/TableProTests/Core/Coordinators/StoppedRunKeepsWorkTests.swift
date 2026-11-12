//
//  StoppedRunKeepsWorkTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

@MainActor
struct StoppedRunKeepsWorkTests {
    private static let script = "INSERT INTO t VALUES (1);\nINSERT INTO t VALUES (2);\nINSERT INTO t VALUES (3);"

    private let connection: DatabaseConnection
    private let storage: QueryHistoryStorage
    private let fixture: CoordinatorFixture

    init() {
        let connection = TestFixtures.makeConnection()
        let storage = QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("stopped_run_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        self.connection = connection
        self.storage = storage
        fixture = CoordinatorFixture(
            connection: connection,
            services: .live.recordingHistory(in: QueryHistoryManager(storage: storage, isCapturePaused: { false }))
        )
    }

    @Test("Stop on Run All in an open transaction keeps the statements that ran, and their history")
    func stopKeepsTheStatementsThatRan() async throws {
        let driver = HeldStatementDriver(connection: connection, holding: 2, onCancel: .keepsRunning)
        defer { finish(driver) }
        let run = try startRun(on: driver)

        try await waitUntil { driver.isHolding }
        fixture.coordinator.stopExecution(for: run.tabId)
        driver.finishHeldStatement()
        await run.handle.value

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == run.tabId })
        #expect(driver.sentStatements.count == 2)
        #expect(tab.display.resultSets.count == 1)
        #expect(tab.display.resultSets.first?.rowsAffected == 2)
        #expect(tab.execution.rowsAffected == 2)
        #expect(tab.execution.statusMessage == PluginSessionTransactionState.inTransaction.openTransactionNotice)
        #expect(fixture.coordinator.tabExecution.isAnyExecuting == false)

        let entries = try await history(count: 2)
        #expect(entries.map { $0.query } == ["INSERT INTO t VALUES (1);", "INSERT INTO t VALUES (2);"])
        #expect(entries.allSatisfy { $0.wasSuccessful })
    }

    @Test("Stop that interrupts a statement reads as a stop: the statements before it are kept, with no error")
    func stopThatInterruptsAStatementKeepsTheOnesBefore() async throws {
        let driver = HeldStatementDriver(connection: connection, holding: 3, onCancel: .failsTheStatement)
        defer { finish(driver) }
        let run = try startRun(on: driver)

        try await waitUntil { driver.isHolding }
        fixture.coordinator.stopExecution(for: run.tabId)
        try await waitUntil { !driver.isHolding }
        await run.handle.value

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == run.tabId })
        let results = tab.display.resultSets
        #expect(driver.sentStatements.count == 3)
        #expect(results.count == 1)
        #expect(results.first?.rowsAffected == 2)
        #expect(results.allSatisfy { $0.errorMessage == nil })
        #expect(tab.execution.errorMessage == nil)
        #expect(tab.execution.statusMessage == PluginSessionTransactionState.inTransaction.openTransactionNotice)
        #expect(fixture.coordinator.tabExecution.isAnyExecuting == false)

        let entries = try await history(count: 2)
        #expect(entries.map { $0.query } == ["INSERT INTO t VALUES (1);", "INSERT INTO t VALUES (2);"])
        #expect(entries.allSatisfy { $0.wasSuccessful })
    }

    @Test("A stopped run that comes back after edits were staged keeps them and only writes history")
    func stoppedRunKeepsEditsStagedAfterStop() async throws {
        let driver = HeldStatementDriver(connection: connection, holding: 2, onCancel: .keepsRunning)
        defer { finish(driver) }
        let run = try startRun(on: driver)

        try await waitUntil { driver.isHolding }
        fixture.coordinator.stopExecution(for: run.tabId)
        let contentAfterStop = fixture.coordinator.tabExecution.contentEpoch(for: run.tabId)
        fixture.changeManager.recordRowDeletion(rowID: .existing(0), originalRow: [.text("1")])
        driver.finishHeldStatement()
        await run.handle.value

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == run.tabId })
        #expect(fixture.changeManager.hasChanges)
        #expect(tab.display.resultSets.isEmpty)
        #expect(fixture.coordinator.tabExecution.isSameContent(contentAfterStop, for: run.tabId))
        #expect(fixture.coordinator.tabExecution.isAnyExecuting == false)

        let entries = try await history(count: 2)
        #expect(entries.map { $0.query } == ["INSERT INTO t VALUES (1);", "INSERT INTO t VALUES (2);"])
    }

    @Test("A run that a new run superseded after its Stop writes nothing")
    func supersededStoppedRunWritesNothing() async throws {
        let driver = HeldStatementDriver(connection: connection, holding: 2, onCancel: .keepsRunning)
        defer { finish(driver) }
        let run = try startRun(on: driver)

        try await waitUntil { driver.isHolding }
        fixture.coordinator.stopExecution(for: run.tabId)
        let successor = fixture.coordinator.beginTabExecution(for: run.tabId)
        driver.finishHeldStatement()
        await run.handle.value

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == run.tabId })
        #expect(tab.display.resultSets.isEmpty)
        #expect(tab.execution.statusMessage == nil)
        #expect(fixture.coordinator.tabExecution.isCurrent(successor.claim))
    }

    private func startRun(on driver: HeldStatementDriver) throws -> (tabId: UUID, handle: Task<Void, Never>) {
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let tab = fixture.addTab(QueryTab(title: "Query", query: Self.script, tabType: .query))
        let statements = SQLStatementScanner.executableStatements(
            in: Self.script, grammar: fixture.coordinator.lexicalGrammar
        )
        fixture.coordinator.queryExecutionCoordinator.executeMultipleStatements(statements)
        let handle = try #require(fixture.coordinator.queryTasks.task(for: tab.id))
        return (tab.id, handle)
    }

    private func finish(_ driver: HeldStatementDriver) {
        driver.finishHeldStatement()
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    // History is written on tasks the run does not await.
    private func history(count: Int) async throws -> [QueryHistoryEntry] {
        let storage = self.storage
        let scope = QueryHistoryScope.connection(connection.id)
        try await waitUntil { await storage.count(scope: scope) == count }
        let page = await storage.fetch(QueryHistoryFilter(scope: scope), after: nil, limit: count + 1)
        return page.entries.sorted { $0.query < $1.query }
    }
}

// Holds the statement at `heldPosition` until the test lets it go, or until a Stop's driver cancel fails it.
private final class HeldStatementDriver: DatabaseDriver, @unchecked Sendable {
    enum OnCancel {
        case keepsRunning
        case failsTheStatement
    }

    struct Interrupted: LocalizedError {
        var errorDescription: String? { "canceling statement due to user request" }
    }

    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }
    var sessionLexicalState: PluginSessionLexicalState? { nil }

    private let heldPosition: Int
    private let onCancel: OnCancel
    private let lock = NSLock()
    private var sent: [String] = []
    private var held: CheckedContinuation<Void, any Error>?

    init(connection: DatabaseConnection, holding heldPosition: Int, onCancel: OnCancel) {
        self.connection = connection
        self.heldPosition = heldPosition
        self.onCancel = onCancel
    }

    var sentStatements: [String] {
        lock.withLock { sent }
    }

    var isHolding: Bool {
        lock.withLock { held != nil }
    }

    func finishHeldStatement() {
        takeHeld()?.resume()
    }

    func cancelQuery() throws {
        guard onCancel == .failsTheStatement else { return }
        takeHeld()?.resume(throwing: Interrupted())
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { .inTransaction }

    private func takeHeld() -> CheckedContinuation<Void, any Error>? {
        lock.withLock {
            let continuation = held
            held = nil
            return continuation
        }
    }

    private func run(_ query: String) async throws -> QueryResult {
        let position = lock.withLock {
            sent.append(query)
            return sent.count
        }
        if position == heldPosition {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { held = continuation }
            }
        }
        return QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 1, executionTime: 0, error: nil)
    }

    func execute(query: String) async throws -> QueryResult { try await run(query) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { try await run(query) }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        try await run(query)
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@MainActor
private extension AppServices {
    func recordingHistory(in queryHistoryManager: QueryHistoryManager) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: schemaProviderRegistry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
