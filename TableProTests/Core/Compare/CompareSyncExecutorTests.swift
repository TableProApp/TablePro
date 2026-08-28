//
//  CompareSyncExecutorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

private final class RecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    var executed: [String] = []
    var transactionEvents: [String] = []
    var failingStatements: Set<String> = []
    var transactionsSupported = true
    var transactionalDDLSupported = true
    var declaredCapabilities: PluginCapabilities = []

    var capabilities: PluginCapabilities { declaredCapabilities }
    var supportsTransactions: Bool { transactionsSupported }
    var supportsTransactionalDDL: Bool { transactionalDDLSupported }

    func connect() async throws {}

    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        executed.append(query)
        if failingStatements.contains(query) {
            throw CompareSyncError.unsupportedOperation("boom")
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func beginTransaction() async throws { transactionEvents.append("begin") }
    func commitTransaction() async throws { transactionEvents.append("commit") }
    func rollbackTransaction() async throws { transactionEvents.append("rollback") }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

private struct AlwaysAllowGate: ExecutionGate {
    func authorize(_ request: OperationRequest) async -> OperationDecision {
        .authorized(OperationReceipt(
            connectionId: request.connectionId,
            kind: request.kind,
            effectiveWrite: true,
            grantedAt: Date(),
            token: UUID()
        ))
    }
}

private struct AlwaysDenyGate: ExecutionGate {
    func authorize(_ request: OperationRequest) async -> OperationDecision {
        .denied(reason: "Read-Only connection")
    }
}

final class CompareSyncExecutorTests: XCTestCase {
    private func endpoint() -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "app", schema: nil),
            connectionName: "staging",
            databaseType: .mysql,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func statement(_ sql: String, refused: Bool = false) -> SyncStatement {
        SyncStatement(
            sql: sql,
            objectName: "t",
            summary: sql,
            hazards: refused
                ? [SyncHazard(kind: .dataLoss, severity: .refusedByDefault, explanation: "drops data")]
                : []
        )
    }

    private func run(
        statements: [SyncStatement],
        settings: CompareSyncExecutionSettings = CompareSyncExecutionSettings(),
        driver: RecordingDriver,
        gate: any ExecutionGate = AlwaysAllowGate()
    ) async throws -> CompareSyncRunResult {
        try await CompareSyncExecutor(gate: gate).apply(
            statements: statements,
            mode: .structure,
            settings: settings,
            target: endpoint(),
            driver: driver,
            progress: Progress()
        )
    }

    // MARK: - Held back statements

    func testRefusedStatementIsNotExecutedUnlessAllowed() async throws {
        let driver = RecordingDriver()
        let dropStatement = statement("DROP TABLE t;", refused: true)

        let result = try await run(statements: [statement("SELECT 1;"), dropStatement], driver: driver)

        XCTAssertEqual(driver.executed, ["SELECT 1;"], "a refused statement must not reach the driver")
        XCTAssertEqual(result.heldBackCount, 1)
        XCTAssertEqual(result.executedCount, 1)
    }

    func testAllowingARefusedStatementRunsIt() async throws {
        let driver = RecordingDriver()
        let dropStatement = statement("DROP TABLE t;", refused: true)
        var settings = CompareSyncExecutionSettings()
        settings.allowedHazardStatementIds = [dropStatement.id]

        let result = try await run(statements: [dropStatement], settings: settings, driver: driver)

        XCTAssertEqual(driver.executed, ["DROP TABLE t;"])
        XCTAssertEqual(result.heldBackCount, 0)
    }

    func testAllRefusedMeansNothingRunsAndNoTransactionOpens() async throws {
        let driver = RecordingDriver()

        let result = try await run(statements: [statement("DROP TABLE t;", refused: true)], driver: driver)

        XCTAssertTrue(driver.executed.isEmpty)
        XCTAssertTrue(driver.transactionEvents.isEmpty)
        XCTAssertEqual(result.heldBackCount, 1)
    }

    // MARK: - Transactions

    func testSuccessfulRunCommits() async throws {
        let driver = RecordingDriver()

        _ = try await run(statements: [statement("A;"), statement("B;")], driver: driver)

        XCTAssertEqual(driver.transactionEvents, ["begin", "commit"])
    }

    func testFailureRollsBackWithStopAndRollback() async throws {
        let driver = RecordingDriver()
        driver.failingStatements = ["B;"]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .stopAndRollback

        let result = try await run(
            statements: [statement("A;"), statement("B;"), statement("C;")],
            settings: settings,
            driver: driver
        )

        XCTAssertEqual(driver.transactionEvents, ["begin", "rollback"])
        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(driver.executed, ["A;", "B;"], "execution stops at the first failure")
    }

    func testFailureCommitsWithStopAndCommit() async throws {
        let driver = RecordingDriver()
        driver.failingStatements = ["B;"]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .stopAndCommit

        let result = try await run(
            statements: [statement("A;"), statement("B;")],
            settings: settings,
            driver: driver
        )

        XCTAssertEqual(driver.transactionEvents, ["begin", "commit"])
        XCTAssertFalse(result.rolledBack)
    }

    func testSkipAndContinueRunsEverythingAndUsesNoTransaction() async throws {
        let driver = RecordingDriver()
        driver.failingStatements = ["B;"]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .skipAndContinue

        let result = try await run(
            statements: [statement("A;"), statement("B;"), statement("C;")],
            settings: settings,
            driver: driver
        )

        XCTAssertEqual(driver.executed, ["A;", "B;", "C;"])
        XCTAssertTrue(driver.transactionEvents.isEmpty, "skip and continue must not open a transaction")
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.executedCount, 2)
    }

    func testNoTransactionWhenDriverDoesNotSupportOne() async throws {
        let driver = RecordingDriver()
        driver.transactionsSupported = false
        driver.transactionalDDLSupported = false

        _ = try await run(statements: [statement("A;")], driver: driver)

        XCTAssertTrue(driver.transactionEvents.isEmpty)
    }

    /// A structure sync on MySQL, MariaDB or Oracle must not open a transaction it cannot roll
    /// back: DDL commits implicitly there, so the ROLLBACK undid nothing while the run reported
    /// "The target is unchanged."
    func testStructureSyncOpensNoTransactionWhenDDLCommitsImplicitly() async throws {
        let driver = RecordingDriver()
        driver.transactionsSupported = true
        driver.transactionalDDLSupported = false

        _ = try await run(statements: [statement("ALTER TABLE users DROP COLUMN legacy_id;")], driver: driver)

        XCTAssertTrue(driver.transactionEvents.isEmpty)
    }

    // MARK: - Gate

    func testDeniedAuthorizationRunsNoStatements() async {
        let driver = RecordingDriver()

        do {
            _ = try await run(statements: [statement("A;")], driver: driver, gate: AlwaysDenyGate())
            XCTFail("Expected the gate to deny the run")
        } catch {
            XCTAssertTrue(driver.executed.isEmpty, "nothing may run when the gate denies")
        }
    }

    // MARK: - Progress

    func testProgressReachesTotalOnCompletion() async throws {
        let driver = RecordingDriver()
        let progress = Progress()

        _ = try await CompareSyncExecutor(gate: AlwaysAllowGate()).apply(
            statements: [statement("A;"), statement("B;"), statement("C;")],
            mode: .structure,
            settings: CompareSyncExecutionSettings(),
            target: endpoint(),
            driver: driver,
            progress: progress
        )

        XCTAssertEqual(progress.totalUnitCount, 3)
        XCTAssertEqual(progress.completedUnitCount, 3)
    }
}

final class CompareSyncExecutionSettingsTests: XCTestCase {
    private func driver(transactions: Bool, transactionalDDL: Bool) -> RecordingDriver {
        let driver = RecordingDriver()
        driver.transactionsSupported = transactions
        driver.transactionalDDLSupported = transactionalDDL
        return driver
    }

    func testTransactionIsDisabledForSkipAndContinue() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .skipAndContinue

        XCTAssertFalse(settings.usesTransaction(
            for: .data, driver: driver(transactions: true, transactionalDDL: true)
        ))
    }

    func testTransactionRequiresDriverSupport() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback

        XCTAssertTrue(settings.usesTransaction(
            for: .data, driver: driver(transactions: true, transactionalDDL: true)
        ))
        XCTAssertFalse(settings.usesTransaction(
            for: .data, driver: driver(transactions: false, transactionalDDL: true)
        ))
    }

    /// MySQL, MariaDB and Oracle commit implicitly on every DDL statement, so a structure sync
    /// wrapped in a transaction reported "The target is unchanged" after a ROLLBACK that undid
    /// nothing. Structure asks `supportsTransactionalDDL`, data asks `supportsTransactions`.
    func testStructureSyncAsksForTransactionalDDLRatherThanTransactions() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback
        let mysqlLike = driver(transactions: true, transactionalDDL: false)

        XCTAssertFalse(settings.usesTransaction(for: .structure, driver: mysqlLike))
        XCTAssertTrue(settings.usesTransaction(for: .data, driver: mysqlLike))
    }

    func testStructureSyncUsesATransactionWhenTheEngineSupportsTransactionalDDL() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback

        XCTAssertTrue(settings.usesTransaction(
            for: .structure, driver: driver(transactions: true, transactionalDDL: true)
        ))
    }
}

final class CompareSyncEligibilityTests: XCTestCase {
    func testMissingSchemaCompareBitIsRefused() {
        let driver = RecordingDriver()
        driver.declaredCapabilities = []

        XCTAssertNotNil(CompareSyncEligibility.refusalReason(for: driver, mode: .structure, endpointName: "db"))
    }

    func testDeclaredBitPasses() {
        let driver = RecordingDriver()
        driver.declaredCapabilities = [.schemaCompare, .dataCompare]

        XCTAssertNil(CompareSyncEligibility.refusalReason(for: driver, mode: .structure, endpointName: "db"))
        XCTAssertNil(CompareSyncEligibility.refusalReason(for: driver, mode: .data, endpointName: "db"))
    }

    func testStructureBitDoesNotGrantDataCompare() {
        let driver = RecordingDriver()
        driver.declaredCapabilities = [.schemaCompare]

        XCTAssertNotNil(CompareSyncEligibility.refusalReason(for: driver, mode: .data, endpointName: "db"))
    }
}

final class DatabaseEndpointSafeModeTests: XCTestCase {
    private func endpoint(_ level: SafeModeLevel) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "prod", schema: nil),
            connectionName: "prod",
            databaseType: .postgresql,
            safeModeLevel: level,
            color: .red
        )
    }

    func testReadOnlyEndpointCannotBeWrittenTo() {
        let target = endpoint(.readOnly)

        XCTAssertFalse(target.canBeWrittenTo)
        XCTAssertNotNil(target.ineligibleAsTargetReason)
    }

    func testOtherLevelsCanBeWrittenTo() {
        for level in [SafeModeLevel.silent, .alert, .alertFull, .safeMode, .safeModeFull] {
            XCTAssertTrue(endpoint(level).canBeWrittenTo, "\(level) should be a valid target")
            XCTAssertNil(endpoint(level).ineligibleAsTargetReason)
        }
    }
}
