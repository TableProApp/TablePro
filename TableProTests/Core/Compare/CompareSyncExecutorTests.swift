//
//  CompareSyncExecutorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class RecordingDriver: PluginDriverStub, @unchecked Sendable {
    var executed: [String] = []
    var transactionEvents: [String] = []
    var failingStatements: Set<String> = []
    var transactionsSupported = true
    var transactionalDDLSupported = true
    var declaredCapabilities: PluginCapabilities = []

    var capabilities: PluginCapabilities { declaredCapabilities }
    var supportsTransactions: Bool { transactionsSupported }
    var supportsTransactionalDDL: Bool { transactionalDDLSupported }

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
}

struct CompareSyncExecutorTests {
    private func endpoint(databaseType: DatabaseType = .mysql) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "app", schema: nil),
            connectionName: "staging",
            databaseType: databaseType,
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
        gate: any ExecutionGate = AlwaysAllowGate(),
        databaseType: DatabaseType = .mysql
    ) async throws -> CompareSyncRunResult {
        try await CompareSyncExecutor(gate: gate).apply(
            statements: statements,
            mode: .structure,
            settings: settings,
            target: endpoint(databaseType: databaseType),
            driver: driver,
            progress: Progress()
        )
    }

    // MARK: - Statement text

    /// A statement already is the text the driver takes, one call each: on Oracle a unit keeps its own `;` and a
    /// CALL trigger has none, and on SQL Server a body the generic grammar would cut stays whole.
    @Test
    func everyStatementGoesOutExactlyAsBuilt() async throws {
        let cases: [(DatabaseType, [String])] = [
            (.oracle, [
                "CREATE OR REPLACE PROCEDURE p IS BEGIN NULL; END;",
                "CREATE OR REPLACE TRIGGER t BEFORE INSERT ON x FOR EACH ROW CALL p(:NEW.a)",
                "CREATE OR REPLACE VIEW v AS SELECT 1 AS a FROM dual",
            ]),
            (.mssql, ["CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;"]),
            (.mysql, ["CREATE PROCEDURE p() BEGIN SELECT 1; END"]),
        ]
        for (databaseType, sql) in cases {
            let driver = RecordingDriver()
            _ = try await run(statements: sql.map { statement($0) }, driver: driver, databaseType: databaseType)
            #expect(driver.executed == sql, "\(databaseType.rawValue)")
        }
    }

    // MARK: - Held back statements

    @Test
    func refusedStatementIsNotExecutedUnlessAllowed() async throws {
        let driver = RecordingDriver()
        let dropStatement = statement("DROP TABLE t;", refused: true)

        let result = try await run(statements: [statement("SELECT 1;"), dropStatement], driver: driver)

        #expect(driver.executed == ["SELECT 1;"], "a refused statement must not reach the driver")
        #expect(result.heldBackCount == 1)
        #expect(result.executedCount == 1)
    }

    @Test
    func allowingARefusedStatementRunsIt() async throws {
        let driver = RecordingDriver()
        let dropStatement = statement("DROP TABLE t;", refused: true)
        var settings = CompareSyncExecutionSettings()
        settings.allowedHazardStatementIds = [dropStatement.id]

        let result = try await run(statements: [dropStatement], settings: settings, driver: driver)

        #expect(driver.executed == ["DROP TABLE t;"])
        #expect(result.heldBackCount == 0)
    }

    @Test
    func allRefusedMeansNothingRunsAndNoTransactionOpens() async throws {
        let driver = RecordingDriver()

        let result = try await run(statements: [statement("DROP TABLE t;", refused: true)], driver: driver)

        #expect(driver.executed.isEmpty)
        #expect(driver.transactionEvents.isEmpty)
        #expect(result.heldBackCount == 1)
    }

    // MARK: - Transactions

    @Test
    func successfulRunCommits() async throws {
        let driver = RecordingDriver()

        _ = try await run(statements: [statement("A;"), statement("B;")], driver: driver)

        #expect(driver.transactionEvents == ["begin", "commit"])
    }

    @Test
    func failureRollsBackWithStopAndRollback() async throws {
        let driver = RecordingDriver()
        driver.failingStatements = ["B;"]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .stopAndRollback

        let result = try await run(
            statements: [statement("A;"), statement("B;"), statement("C;")],
            settings: settings,
            driver: driver
        )

        #expect(driver.transactionEvents == ["begin", "rollback"])
        #expect(result.rolledBack)
        #expect(driver.executed == ["A;", "B;"], "execution stops at the first failure")
    }

    @Test
    func failureCommitsWithStopAndCommit() async throws {
        let driver = RecordingDriver()
        driver.failingStatements = ["B;"]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .stopAndCommit

        let result = try await run(
            statements: [statement("A;"), statement("B;")],
            settings: settings,
            driver: driver
        )

        #expect(driver.transactionEvents == ["begin", "commit"])
        #expect(!result.rolledBack)
    }

    @Test
    func skipAndContinueRunsEverythingAndUsesNoTransaction() async throws {
        let driver = RecordingDriver()
        driver.failingStatements = ["B;"]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .skipAndContinue

        let result = try await run(
            statements: [statement("A;"), statement("B;"), statement("C;")],
            settings: settings,
            driver: driver
        )

        #expect(driver.executed == ["A;", "B;", "C;"])
        #expect(driver.transactionEvents.isEmpty, "skip and continue must not open a transaction")
        #expect(result.failedCount == 1)
        #expect(result.executedCount == 2)
    }

    @Test
    func noTransactionWhenDriverDoesNotSupportOne() async throws {
        let driver = RecordingDriver()
        driver.transactionsSupported = false
        driver.transactionalDDLSupported = false

        _ = try await run(statements: [statement("A;")], driver: driver)

        #expect(driver.transactionEvents.isEmpty)
    }

    /// A structure sync on MySQL, MariaDB or Oracle must not open a transaction it cannot roll
    /// back: DDL commits implicitly there, so the ROLLBACK undid nothing while the run reported
    /// "The target is unchanged."
    @Test
    func structureSyncOpensNoTransactionWhenDDLCommitsImplicitly() async throws {
        let driver = RecordingDriver()
        driver.transactionsSupported = true
        driver.transactionalDDLSupported = false

        _ = try await run(statements: [statement("ALTER TABLE users DROP COLUMN legacy_id;")], driver: driver)

        #expect(driver.transactionEvents.isEmpty)
    }

    // MARK: - Gate

    @Test
    func deniedAuthorizationRunsNoStatements() async {
        let driver = RecordingDriver()

        do {
            _ = try await run(statements: [statement("A;")], driver: driver, gate: AlwaysDenyGate())
            Issue.record("Expected the gate to deny the run")
        } catch {
            #expect(driver.executed.isEmpty, "nothing may run when the gate denies")
        }
    }

    // MARK: - Progress

    @Test
    func progressReachesTotalOnCompletion() async throws {
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

        #expect(progress.totalUnitCount == 3)
        #expect(progress.completedUnitCount == 3)
    }
}

struct CompareSyncExecutionSettingsTests {
    private func driver(transactions: Bool, transactionalDDL: Bool) -> RecordingDriver {
        let driver = RecordingDriver()
        driver.transactionsSupported = transactions
        driver.transactionalDDLSupported = transactionalDDL
        return driver
    }

    @Test
    func transactionIsDisabledForSkipAndContinue() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .skipAndContinue

        #expect(!(settings.usesTransaction(
            for: .data, driver: driver(transactions: true, transactionalDDL: true)
        )))
    }

    @Test
    func transactionRequiresDriverSupport() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback

        #expect(settings.usesTransaction(
            for: .data, driver: driver(transactions: true, transactionalDDL: true)
        ))
        #expect(!(settings.usesTransaction(
            for: .data, driver: driver(transactions: false, transactionalDDL: true)
        )))
    }

    /// MySQL, MariaDB and Oracle commit implicitly on every DDL statement, so a structure sync
    /// wrapped in a transaction reported "The target is unchanged" after a ROLLBACK that undid
    /// nothing. Structure asks `supportsTransactionalDDL`, data asks `supportsTransactions`.
    @Test
    func structureSyncAsksForTransactionalDDLRatherThanTransactions() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback
        let mysqlLike = driver(transactions: true, transactionalDDL: false)

        #expect(!settings.usesTransaction(for: .structure, driver: mysqlLike))
        #expect(settings.usesTransaction(for: .data, driver: mysqlLike))
    }

    @Test
    func structureSyncUsesATransactionWhenTheEngineSupportsTransactionalDDL() {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback

        #expect(settings.usesTransaction(
            for: .structure, driver: driver(transactions: true, transactionalDDL: true)
        ))
    }
}

struct CompareSyncEligibilityTests {
    @Test
    func missingSchemaCompareBitIsRefused() {
        let driver = RecordingDriver()
        driver.declaredCapabilities = []

        #expect(CompareSyncEligibility.refusalReason(for: driver, mode: .structure, endpointName: "db") != nil)
    }

    @Test
    func declaredBitPasses() {
        let driver = RecordingDriver()
        driver.declaredCapabilities = [.schemaCompare, .dataCompare]

        #expect(CompareSyncEligibility.refusalReason(for: driver, mode: .structure, endpointName: "db") == nil)
        #expect(CompareSyncEligibility.refusalReason(for: driver, mode: .data, endpointName: "db") == nil)
    }

    @Test
    func structureBitDoesNotGrantDataCompare() {
        let driver = RecordingDriver()
        driver.declaredCapabilities = [.schemaCompare]

        #expect(CompareSyncEligibility.refusalReason(for: driver, mode: .data, endpointName: "db") != nil)
    }
}

struct DatabaseEndpointSafeModeTests {
    private func endpoint(_ level: SafeModeLevel) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "prod", schema: nil),
            connectionName: "prod",
            databaseType: .postgresql,
            safeModeLevel: level,
            color: .red
        )
    }

    @Test
    func readOnlyEndpointCannotBeWrittenTo() {
        let target = endpoint(.readOnly)

        #expect(!target.canBeWrittenTo)
        #expect(target.ineligibleAsTargetReason != nil)
    }

    @Test
    func otherLevelsCanBeWrittenTo() {
        for level in [SafeModeLevel.silent, .alert, .alertFull, .safeMode, .safeModeFull] {
            #expect(endpoint(level).canBeWrittenTo, "\(level) should be a valid target")
            #expect(endpoint(level).ineligibleAsTargetReason == nil)
        }
    }
}
