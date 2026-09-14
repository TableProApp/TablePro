//
//  CompareSyncExecutorScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

private final class ScopeRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let beginEvent = "<begin>"
    static let commitEvent = "<commit>"
    static let rollbackEvent = "<rollback>"

    var executed: [String] = []
    var events: [String] = []
    var failingStatements: Set<String> = []
    var rowsAffectedByStatement: [String: Int] = [:]
    var progressCancellingStatement: String?
    var progressToCancel: Progress?
    var taskCancellingStatement: String?

    var capabilities: PluginCapabilities { [] }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    func connect() async throws {}

    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        executed.append(query)
        events.append(query)
        if query == progressCancellingStatement {
            progressToCancel?.cancel()
        }
        if query == taskCancellingStatement {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if failingStatements.contains(query) {
            throw CompareSyncError.unsupportedOperation("boom")
        }
        return PluginQueryResult(
            columns: [],
            columnTypeNames: [],
            rows: [],
            rowsAffected: rowsAffectedByStatement[query] ?? 0,
            executionTime: 0
        )
    }

    func beginTransaction() async throws { events.append(Self.beginEvent) }
    func commitTransaction() async throws { events.append(Self.commitEvent) }
    func rollbackTransaction() async throws { events.append(Self.rollbackEvent) }

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

private enum ScopeFixture {
    static let begin = ScopeRecordingDriver.beginEvent
    static let commit = ScopeRecordingDriver.commitEvent
    static let rollback = ScopeRecordingDriver.rollbackEvent

    static let identityOn = "SET IDENTITY_INSERT dbo.orders ON;"
    static let identityOff = "SET IDENTITY_INSERT dbo.orders OFF;"
    static let identityScope = "identity-insert:dbo.orders"

    static func endpoint() -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: "dbo"),
            connectionName: "staging",
            databaseType: .mssql,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    static func statement(
        _ sql: String,
        objectName: String = "dbo.orders",
        expectedRowCount: Int? = nil,
        sessionEffect: SyncSessionEffect? = nil
    ) -> SyncStatement {
        SyncStatement(
            sql: sql,
            objectName: objectName,
            summary: sql,
            expectedRowCount: expectedRowCount,
            sessionEffect: sessionEffect
        )
    }

    static func openIdentityInsert() -> SyncStatement {
        statement(identityOn, sessionEffect: .opens(scope: identityScope, closingSQL: identityOff))
    }

    static func closeIdentityInsert() -> SyncStatement {
        statement(identityOff, sessionEffect: .closes(scope: identityScope))
    }

    static func insert(id: Int) -> SyncStatement {
        statement("INSERT INTO dbo.orders (id, total) VALUES (\(id), 5);", expectedRowCount: 1)
    }

    static func auditInsert(id: Int) -> SyncStatement {
        statement(
            "INSERT INTO shop.audit_log (id, note) VALUES (\(id), 'x');",
            objectName: "shop.audit_log",
            expectedRowCount: 1
        )
    }
}

final class CompareSyncExecutorScopeTests: XCTestCase {
    private func run(
        _ statements: [SyncStatement],
        driver: ScopeRecordingDriver,
        settings: CompareSyncExecutionSettings = CompareSyncExecutionSettings(),
        progress: Progress = Progress(),
        nonTransactionalObjects: Set<String> = []
    ) async throws -> CompareSyncRunResult {
        try await CompareSyncExecutor(gate: AlwaysAllowGate()).apply(
            statements: statements,
            mode: .data,
            settings: settings,
            target: ScopeFixture.endpoint(),
            driver: driver,
            progress: progress,
            nonTransactionalObjects: nonTransactionalObjects
        )
    }

    private func stopAndRollback() -> CompareSyncExecutionSettings {
        var settings = CompareSyncExecutionSettings()
        settings.wrapInTransaction = true
        settings.errorHandling = .stopAndRollback
        return settings
    }

    // MARK: - Row count verification

    func testMoreRowsAffectedThanExpectedFailsTheStatementAndRollsBack() async throws {
        let driver = ScopeRecordingDriver()
        let first = ScopeFixture.statement("UPDATE dbo.orders SET total = 5 WHERE id = 1;", expectedRowCount: 1)
        let widened = ScopeFixture.statement("UPDATE dbo.orders SET total = 7 WHERE id = 2;", expectedRowCount: 1)
        let later = ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 3;", expectedRowCount: 1)
        driver.rowsAffectedByStatement = [first.sql: 1, widened.sql: 2, later.sql: 1]

        let result = try await run([first, widened, later], driver: driver, settings: stopAndRollback())

        let failure = try XCTUnwrap(result.outcomes.first { $0.id == widened.id })
        XCTAssertNotNil(failure.error)
        XCTAssertFalse(failure.succeeded)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.executedCount, 1)
        XCTAssertTrue(result.rolledBack)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(
            driver.events,
            [ScopeFixture.begin, first.sql, widened.sql, ScopeFixture.rollback]
        )
    }

    /// MySQL reports zero affected rows for an UPDATE that writes the value the row already holds.
    func testZeroRowsAffectedForAnExpectedOneIsNotAFailure() async throws {
        let driver = ScopeRecordingDriver()
        let update = ScopeFixture.statement("UPDATE dbo.orders SET total = 5 WHERE id = 1;", expectedRowCount: 1)
        driver.rowsAffectedByStatement = [update.sql: 0]

        let result = try await run([update], driver: driver, settings: stopAndRollback())

        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.executedCount, 1)
        XCTAssertFalse(result.rolledBack)
        XCTAssertEqual(driver.events, [ScopeFixture.begin, update.sql, ScopeFixture.commit])
    }

    func testExactlyTheExpectedRowCountIsNotAFailure() async throws {
        let driver = ScopeRecordingDriver()
        let delete = ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 1;", expectedRowCount: 1)
        driver.rowsAffectedByStatement = [delete.sql: 1]

        let result = try await run([delete], driver: driver, settings: stopAndRollback())

        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.executedCount, 1)
        XCTAssertEqual(driver.events.last, ScopeFixture.commit)
    }

    func testStatementWithoutAnExpectedRowCountIsNotVerified() async throws {
        let driver = ScopeRecordingDriver()
        let bulk = ScopeFixture.statement("DELETE FROM dbo.orders WHERE total = 0;")
        driver.rowsAffectedByStatement = [bulk.sql: 40]

        let result = try await run([bulk], driver: driver, settings: stopAndRollback())

        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.executedCount, 1)
        XCTAssertFalse(result.rolledBack)
    }

    // MARK: - Session scopes

    func testScopeLeftOpenByAStoppedRunIsClosedBeforeTheRollback() async throws {
        let driver = ScopeRecordingDriver()
        let insert = ScopeFixture.insert(id: 1)
        let close = ScopeFixture.closeIdentityInsert()
        driver.failingStatements = [insert.sql]

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), insert, close],
            driver: driver,
            settings: stopAndRollback()
        )

        XCTAssertEqual(
            driver.events,
            [ScopeFixture.begin, ScopeFixture.identityOn, insert.sql, ScopeFixture.identityOff, ScopeFixture.rollback]
        )
        XCTAssertTrue(result.rolledBack)
        XCTAssertFalse(result.cancelled)
        XCTAssertFalse(result.outcomes.contains { $0.id == close.id }, "the closing statement itself never ran")
    }

    func testScopeLeftOpenByAStopAndCommitRunIsClosedBeforeTheCommit() async throws {
        let driver = ScopeRecordingDriver()
        let insert = ScopeFixture.insert(id: 1)
        driver.failingStatements = [insert.sql]
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = .stopAndCommit

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), insert, ScopeFixture.closeIdentityInsert()],
            driver: driver,
            settings: settings
        )

        XCTAssertEqual(
            driver.events,
            [ScopeFixture.begin, ScopeFixture.identityOn, insert.sql, ScopeFixture.identityOff, ScopeFixture.commit]
        )
        XCTAssertFalse(result.rolledBack)
    }

    func testScopesLeftOpenAreClosedInReverseOrderOfOpening() async throws {
        let driver = ScopeRecordingDriver()
        let disableForeignKeys = ScopeFixture.statement(
            "SET FOREIGN_KEY_CHECKS = 0;",
            sessionEffect: .opens(scope: "foreign-key-checks", closingSQL: "SET FOREIGN_KEY_CHECKS = 1;")
        )
        let disableUniqueChecks = ScopeFixture.statement(
            "SET UNIQUE_CHECKS = 0;",
            sessionEffect: .opens(scope: "unique-checks", closingSQL: "SET UNIQUE_CHECKS = 1;")
        )
        let insert = ScopeFixture.insert(id: 1)
        driver.failingStatements = [insert.sql]

        _ = try await run(
            [disableForeignKeys, disableUniqueChecks, insert],
            driver: driver,
            settings: stopAndRollback()
        )

        XCTAssertEqual(
            driver.events,
            [
                ScopeFixture.begin,
                "SET FOREIGN_KEY_CHECKS = 0;",
                "SET UNIQUE_CHECKS = 0;",
                insert.sql,
                "SET UNIQUE_CHECKS = 1;",
                "SET FOREIGN_KEY_CHECKS = 1;",
                ScopeFixture.rollback
            ]
        )
    }

    /// A statement that failed to open its scope changed no session state, so there is nothing to close.
    func testScopeWhoseOpeningStatementFailedIsNotClosed() async throws {
        let driver = ScopeRecordingDriver()
        driver.failingStatements = [ScopeFixture.identityOn]

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), ScopeFixture.insert(id: 1), ScopeFixture.closeIdentityInsert()],
            driver: driver,
            settings: stopAndRollback()
        )

        XCTAssertEqual(driver.events, [ScopeFixture.begin, ScopeFixture.identityOn, ScopeFixture.rollback])
        XCTAssertTrue(result.rolledBack)
    }

    func testRunCancelledBeforeApplyExecutesNothingAndDoesNotCommit() async throws {
        let driver = ScopeRecordingDriver()
        let progress = Progress()
        progress.isCancellable = true
        progress.cancel()

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), ScopeFixture.insert(id: 1), ScopeFixture.closeIdentityInsert()],
            driver: driver,
            settings: stopAndRollback(),
            progress: progress
        )

        XCTAssertTrue(driver.executed.isEmpty, "a scope that never opened has nothing to close")
        XCTAssertFalse(driver.events.contains(ScopeFixture.commit))
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.executedCount, 0)
        XCTAssertEqual(progress.completedUnitCount, 0)
    }

    func testProgressCancelledMidRunClosesTheOpenScopeBeforeTheRollback() async throws {
        let driver = ScopeRecordingDriver()
        let progress = Progress()
        let insert = ScopeFixture.insert(id: 1)
        let close = ScopeFixture.closeIdentityInsert()
        driver.rowsAffectedByStatement = [insert.sql: 1]
        driver.progressCancellingStatement = insert.sql
        driver.progressToCancel = progress

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), insert, close],
            driver: driver,
            settings: stopAndRollback(),
            progress: progress
        )

        XCTAssertEqual(
            driver.events,
            [ScopeFixture.begin, ScopeFixture.identityOn, insert.sql, ScopeFixture.identityOff, ScopeFixture.rollback]
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.rolledBack)
        XCTAssertFalse(result.outcomes.contains { $0.id == close.id })
    }

    func testTaskCancelledMidRunClosesTheOpenScopeBeforeTheRollback() async throws {
        let driver = ScopeRecordingDriver()
        let insert = ScopeFixture.insert(id: 1)
        let statements = [ScopeFixture.openIdentityInsert(), insert, ScopeFixture.closeIdentityInsert()]
        let target = ScopeFixture.endpoint()
        driver.rowsAffectedByStatement = [insert.sql: 1]
        driver.taskCancellingStatement = insert.sql

        let task = Task { () async throws -> (cancelled: Bool, rolledBack: Bool) in
            let result = try await CompareSyncExecutor(gate: AlwaysAllowGate()).apply(
                statements: statements,
                mode: .data,
                settings: CompareSyncExecutionSettings(),
                target: target,
                driver: driver,
                progress: Progress()
            )
            return (result.cancelled, result.rolledBack)
        }
        let outcome = try await task.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertTrue(outcome.rolledBack)
        XCTAssertEqual(
            driver.events,
            [ScopeFixture.begin, ScopeFixture.identityOn, insert.sql, ScopeFixture.identityOff, ScopeFixture.rollback]
        )
    }

    func testScopeClosedByItsOwnStatementIsNotClosedAgainOnSuccess() async throws {
        let driver = ScopeRecordingDriver()
        let insert = ScopeFixture.insert(id: 1)
        driver.rowsAffectedByStatement = [insert.sql: 1]

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), insert, ScopeFixture.closeIdentityInsert()],
            driver: driver,
            settings: stopAndRollback()
        )

        XCTAssertEqual(
            driver.events,
            [ScopeFixture.begin, ScopeFixture.identityOn, insert.sql, ScopeFixture.identityOff, ScopeFixture.commit]
        )
        XCTAssertEqual(result.executedCount, 3)
    }

    func testScopeClosedByItsOwnStatementIsNotClosedAgainWhenALaterStatementFails() async throws {
        let driver = ScopeRecordingDriver()
        let insert = ScopeFixture.insert(id: 1)
        let delete = ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 9;", expectedRowCount: 1)
        driver.rowsAffectedByStatement = [insert.sql: 1]
        driver.failingStatements = [delete.sql]

        let result = try await run(
            [ScopeFixture.openIdentityInsert(), insert, ScopeFixture.closeIdentityInsert(), delete],
            driver: driver,
            settings: stopAndRollback()
        )

        XCTAssertEqual(driver.executed.filter { $0 == ScopeFixture.identityOff }.count, 1)
        XCTAssertEqual(
            driver.events,
            [
                ScopeFixture.begin,
                ScopeFixture.identityOn,
                insert.sql,
                ScopeFixture.identityOff,
                delete.sql,
                ScopeFixture.rollback
            ]
        )
        XCTAssertTrue(result.rolledBack)
    }

    // MARK: - Non-transactional tables

    func testStoppedRunOverANonTransactionalTableReportsWritesLeftInPlace() async throws {
        let driver = ScopeRecordingDriver()
        let first = ScopeFixture.auditInsert(id: 1)
        let second = ScopeFixture.auditInsert(id: 2)
        driver.rowsAffectedByStatement = [first.sql: 1]
        driver.failingStatements = [second.sql]

        let result = try await run(
            [first, second],
            driver: driver,
            settings: stopAndRollback(),
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(result.nonTransactionalObjects, ["shop.audit_log"])
        XCTAssertTrue(result.rollbackLeftWritesInPlace)
    }

    func testRunThatFailedOnItsFirstStatementLeavesNoWritesInPlace() async throws {
        let driver = ScopeRecordingDriver()
        let first = ScopeFixture.auditInsert(id: 1)
        driver.failingStatements = [first.sql]

        let result = try await run(
            [first, ScopeFixture.auditInsert(id: 2)],
            driver: driver,
            settings: stopAndRollback(),
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertTrue(result.rolledBack)
        XCTAssertFalse(result.rollbackLeftWritesInPlace)
    }

    /// The warning names what ran, not what the script mentioned. A MyISAM table the run never
    /// reached has nothing written in it, and naming it sends the user looking for rows that are
    /// not there.
    func testANonTransactionalTableTheRunNeverReachedIsNotReported() async throws {
        let driver = ScopeRecordingDriver()
        let first = ScopeFixture.insert(id: 1)
        driver.rowsAffectedByStatement = [first.sql: 1]
        driver.failingStatements = [ScopeFixture.insert(id: 2).sql]

        let result = try await run(
            [first, ScopeFixture.insert(id: 2), ScopeFixture.auditInsert(id: 3)],
            driver: driver,
            settings: stopAndRollback(),
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(result.nonTransactionalObjects, [])
        XCTAssertFalse(result.rollbackLeftWritesInPlace)
    }
}

final class CompareSyncExecutorDigestTests: XCTestCase {
    private static let hexDigits = Set("0123456789abcdef")

    func testDigestEndsWithTheStatementCountAndA64CharacterSHA256() throws {
        let statements = [
            ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 1;"),
            ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 2;")
        ]

        let digest = CompareSyncExecutor.digest(of: statements)

        XCTAssertTrue(digest.hasPrefix("DELETE FROM dbo.orders WHERE id = 1;\n"))
        XCTAssertTrue(digest.hasSuffix("\n"))
        let trailer = try XCTUnwrap(digest.split(separator: "\n").last.map { String($0) })
        let trailerPrefix = "-- 2 statements, SHA-256 "
        XCTAssertTrue(trailer.hasPrefix(trailerPrefix), trailer)
        let hash = trailer.dropFirst(trailerPrefix.count)
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { Self.hexDigits.contains($0) }, String(hash))
    }

    func testDigestDependsOnTheScriptAndNotOnStatementIdentity() {
        let sql = ["UPDATE dbo.orders SET total = 5 WHERE id = 1;", "DELETE FROM dbo.orders WHERE id = 2;"]

        let first = CompareSyncExecutor.digest(of: sql.map { ScopeFixture.statement($0) })
        let second = CompareSyncExecutor.digest(of: sql.map { ScopeFixture.statement($0) })

        XCTAssertEqual(first, second)
    }

    func testScriptsSharingTheirFirstTenThousandCharactersButDifferingLaterHaveDifferentDigests() {
        let longInsert = "INSERT INTO dbo.notes (body) VALUES ('\(String(repeating: "a", count: 10_000))');"
        let firstScript = [
            ScopeFixture.statement(longInsert),
            ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 1;")
        ]
        let secondScript = [
            ScopeFixture.statement(longInsert),
            ScopeFixture.statement("DELETE FROM dbo.orders WHERE id = 2;")
        ]

        let first = CompareSyncExecutor.digest(of: firstScript)
        let second = CompareSyncExecutor.digest(of: secondScript)

        XCTAssertEqual(
            Array(first.split(separator: "\n").dropLast()),
            Array(second.split(separator: "\n").dropLast()),
            "the previews are identical, so only the trailer can tell the scripts apart"
        )
        XCTAssertNotEqual(first, second)
    }
}

final class CompareSyncRunResultRollbackTests: XCTestCase {
    /// A statement that ran is what puts rows in a table that cannot roll them back, so the
    /// outcomes here say whether the target was reached, not only whether it answered.
    private func outcome(
        error: String? = nil,
        wasSkipped: Bool = false,
        didExecute: Bool? = nil
    ) -> SyncStatementOutcome {
        let statement = ScopeFixture.auditInsert(id: 1)
        return SyncStatementOutcome(
            id: statement.id,
            statement: statement,
            error: error,
            wasSkipped: wasSkipped,
            didExecute: didExecute ?? (error == nil && !wasSkipped)
        )
    }

    func testRolledBackRunThatWroteANonTransactionalTableLeftWritesInPlace() {
        let result = CompareSyncRunResult(
            outcomes: [outcome(), outcome(error: "boom")],
            rolledBack: true,
            cancelled: false,
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertTrue(result.rollbackLeftWritesInPlace)
    }

    func testRunThatWasNotRolledBackLeftNothingInPlace() {
        let result = CompareSyncRunResult(
            outcomes: [outcome()],
            rolledBack: false,
            cancelled: false,
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertFalse(result.rollbackLeftWritesInPlace)
    }

    func testRollbackOverTransactionalTablesOnlyLeftNothingInPlace() {
        let result = CompareSyncRunResult(
            outcomes: [outcome(), outcome(error: "boom")],
            rolledBack: true,
            cancelled: false,
            nonTransactionalObjects: []
        )

        XCTAssertFalse(result.rollbackLeftWritesInPlace)
    }

    func testRollbackWhereNothingExecutedLeftNothingInPlace() {
        let result = CompareSyncRunResult(
            outcomes: [outcome(error: "boom"), outcome(wasSkipped: true)],
            rolledBack: true,
            cancelled: false,
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertFalse(result.rollbackLeftWritesInPlace)
    }

    /// A statement whose row count came back wider than the script expected is reported as a
    /// failure, and it still wrote the rows. Reading the error as "nothing happened" is how a
    /// rolled-back run over a MyISAM table told the user their target was untouched.
    func testAStatementThatWroteAndThenFailedVerificationLeftWritesInPlace() {
        let result = CompareSyncRunResult(
            outcomes: [outcome(error: "too many rows", didExecute: true)],
            rolledBack: true,
            cancelled: false,
            nonTransactionalObjects: ["shop.audit_log"]
        )

        XCTAssertTrue(result.rollbackLeftWritesInPlace)
    }
}

final class DataSyncTransactionalityTests: XCTestCase {
    func testMyISAMCannotRollBackOnMySQLAndMariaDB() {
        XCTAssertTrue(DataSyncTransactionality.cannotRollBack(storageEngine: "MyISAM", databaseType: .mysql))
        XCTAssertTrue(DataSyncTransactionality.cannotRollBack(storageEngine: "MyISAM", databaseType: .mariadb))
    }

    func testInnoDBCanRollBackOnMySQLAndMariaDB() {
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: "InnoDB", databaseType: .mysql))
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: "InnoDB", databaseType: .mariadb))
    }

    func testPostgreSQLNeverReportsAnEngineThatCannotRollBack() {
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: "MyISAM", databaseType: .postgresql))
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: "InnoDB", databaseType: .postgresql))
    }

    func testUnknownEngineIsNotReportedAsUnableToRollBack() {
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: nil, databaseType: .mysql))
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: nil, databaseType: .mariadb))
        XCTAssertFalse(DataSyncTransactionality.cannotRollBack(storageEngine: "", databaseType: .mysql))
    }
}
