//
//  ImportServiceSessionScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct ScopeRefusal: Error {}

private final class SessionScopeDriver: PluginDriverStub, @unchecked Sendable {
    static let failure = "[1292] Incorrect date value: '0000-00-00' for column 'start_date' at row 1"
    static let preserved = PluginSessionScope(
        purpose: .preserve,
        saved: [PluginSessionSetting(name: "sql_mode", value: "STRICT_TRANS_TABLES,NO_ZERO_DATE")],
        applied: []
    )

    var transactionState: PluginSessionTransactionState = .unknown
    var statesAfter: [String: PluginSessionTransactionState] = [:]
    var failingStatements: Set<String> = []
    var opensScope = true
    var openError: (any Error)?
    var closeError: (any Error)?
    private(set) var events: [String] = []
    private(set) var openedPurposes: [PluginSessionPurpose] = []
    private(set) var closedScopes: [PluginSessionScope] = []

    func execute(query: String) async throws -> PluginQueryResult {
        events.append(query)
        if let next = statesAfter[query] { transactionState = next }
        if failingStatements.contains(query) {
            throw DatabaseError.queryFailed(Self.failure)
        }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}

    func sessionTransactionState() async -> PluginSessionTransactionState {
        transactionState
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        events.append("open")
        openedPurposes.append(purpose)
        if let openError { throw openError }
        return opensScope ? Self.preserved : nil
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        events.append("close")
        closedScopes.append(scope)
        if let closeError { throw closeError }
    }
}

/// Runs its statements the way the SQL import's "Stop and Rollback" does: one transaction, a failure or a cancel
/// rolls it back, then the error goes on.
private final class ScriptedImportPlugin: ImportFormatPlugin {
    static let pluginName = "Scripted Import"
    static let pluginVersion = "1.0"
    static let pluginDescription = "An import format that runs a fixed list of statements"
    static let formatId = "tablepro-tests-scripted-import"
    static let formatDisplayName = "Scripted"
    static let acceptedFileExtensions = ["sql"]
    static let iconName = "doc"
    static let requiresTargetTable = true

    private let statements: [String]
    private let cancelsBeforeLine: Int?

    required init() {
        statements = []
        cancelsBeforeLine = nil
    }

    init(statements: [String], cancelsBeforeLine: Int? = nil) {
        self.statements = statements
        self.cancelsBeforeLine = cancelsBeforeLine
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        try await sink.beginTransaction()
        do {
            for (index, statement) in statements.enumerated() {
                let line = index + 1
                if line == cancelsBeforeLine { progress.cancel() }
                try progress.checkCancellation()
                do {
                    try await sink.execute(statement: statement, line: line)
                } catch {
                    throw PluginImportError.statementFailed(statement: statement, line: line, underlyingError: error)
                }
            }
            try await sink.commitTransaction()
        } catch {
            try? await sink.rollbackTransaction()
            throw error
        }
        return PluginImportResult(executedStatements: statements.count, executionTime: 0)
    }
}

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

private struct ImportRun {
    let service: ImportService
    let result: Result<PluginImportResult, any Error>

    var error: (any Error)? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}

/// The import runs the file on the editor's own session, so what the file sets has to be put back however the
/// import ends. A failed import left a dump's `SET NAMES` and `SQL_MODE` on the session the user kept typing into.
@MainActor
struct ImportServiceSessionScopeTests {
    private func runImport(_ plugin: ScriptedImportPlugin, on driver: SessionScopeDriver) async throws -> ImportRun {
        let connection = TestFixtures.makeConnection(database: "school", type: .mysql)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "school"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let formatId = "\(ScriptedImportPlugin.formatId)-\(UUID().uuidString)"
        PluginManager.shared.importPlugins[formatId] = plugin
        defer { PluginManager.shared.importPlugins[formatId] = nil }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-scope-import-\(UUID().uuidString)")
            .appendingPathExtension("sql")
        try Data("SELECT 1;\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let service = ImportService(connection: connection, historyRecorder: DiscardingHistory(), gate: AlwaysAllowGate())
        do {
            let result = try await service.importFile(
                from: file,
                formatId: formatId,
                encoding: .utf8,
                scope: DatabaseScope(connectionId: connection.id, database: "school", schema: nil)
            )
            return ImportRun(service: service, result: .success(result))
        } catch {
            return ImportRun(service: service, result: .failure(error))
        }
    }

    @Test("A successful import opens one preserving scope and closes it after the commit")
    func successClosesTheScope() async throws {
        let driver = SessionScopeDriver()

        let run = try await runImport(ScriptedImportPlugin(statements: ["INSERT INTO courses VALUES (1)"]), on: driver)

        _ = try run.result.get()
        #expect(driver.openedPurposes == [.preserve])
        #expect(driver.events == ["open", "BEGIN", "INSERT INTO courses VALUES (1)", "COMMIT", "close"])
        #expect(driver.closedScopes == [SessionScopeDriver.preserved])
        #expect(run.service.state.transactionOutcome == .committed)
    }

    @Test("A failing statement closes the scope after the rollback")
    func failureClosesTheScope() async throws {
        let driver = SessionScopeDriver()
        driver.failingStatements = ["INSERT INTO courses VALUES ('0000-00-00')"]

        let run = try await runImport(
            ScriptedImportPlugin(statements: ["SET NAMES utf8mb4", "INSERT INTO courses VALUES ('0000-00-00')"]),
            on: driver
        )

        #expect(run.error is PluginImportError)
        #expect(driver.events == [
            "open", "BEGIN", "SET NAMES utf8mb4", "INSERT INTO courses VALUES ('0000-00-00')", "ROLLBACK", "close",
        ])
        #expect(run.service.state.transactionOutcome == .rolledBack)
    }

    @Test("A cancelled import closes the scope after the rollback, and says it rolled back")
    func cancelClosesTheScope() async throws {
        let driver = SessionScopeDriver()

        let run = try await runImport(
            ScriptedImportPlugin(statements: ["SET NAMES utf8mb4", "INSERT INTO courses VALUES (1)"], cancelsBeforeLine: 2),
            on: driver
        )

        #expect(run.error is PluginImportCancellationError)
        #expect(driver.events == ["open", "BEGIN", "SET NAMES utf8mb4", "ROLLBACK", "close"])
        #expect(run.service.state.transactionOutcome == .rolledBack)
    }

    @Test("A cancel after the server committed the transaction says what ran was kept")
    func cancelAfterACommitReportsIt() async throws {
        let driver = SessionScopeDriver()
        driver.transactionState = .idle
        driver.statesAfter = ["BEGIN": .inTransaction, "DROP TABLE IF EXISTS courses": .idle]

        let run = try await runImport(
            ScriptedImportPlugin(
                statements: ["DROP TABLE IF EXISTS courses", "INSERT INTO courses VALUES (1)"],
                cancelsBeforeLine: 2
            ),
            on: driver
        )

        #expect(run.error is PluginImportCancellationError)
        #expect(driver.events == ["open", "BEGIN", "DROP TABLE IF EXISTS courses", "close"])
        #expect(run.service.state.transactionOutcome == .committedBeforeRollback)
    }

    @Test("A cancel inside the user's own transaction reports no transaction of the import's")
    func cancelInsideTheUsersTransaction() async throws {
        let driver = SessionScopeDriver()
        driver.transactionState = .inTransaction

        let run = try await runImport(
            ScriptedImportPlugin(statements: ["SET NAMES utf8mb4", "INSERT INTO courses VALUES (1)"], cancelsBeforeLine: 2),
            on: driver
        )

        #expect(run.error is PluginImportCancellationError)
        #expect(driver.events == ["open", "SET NAMES utf8mb4", "close"])
        #expect(run.service.state.transactionOutcome == .untracked)
    }

    @Test("A scope that fails to open leaves the import to run as before")
    func openFailureDoesNotStopTheImport() async throws {
        let driver = SessionScopeDriver()
        driver.openError = ScopeRefusal()

        let run = try await runImport(ScriptedImportPlugin(statements: ["INSERT INTO courses VALUES (1)"]), on: driver)

        #expect(try run.result.get().executedStatements == 1)
        #expect(driver.events == ["open", "BEGIN", "INSERT INTO courses VALUES (1)", "COMMIT"])
    }

    @Test("A driver with nothing to hold gets no close")
    func noScopeGetsNoClose() async throws {
        let driver = SessionScopeDriver()
        driver.opensScope = false

        let run = try await runImport(ScriptedImportPlugin(statements: ["INSERT INTO courses VALUES (1)"]), on: driver)

        _ = try run.result.get()
        #expect(driver.closedScopes.isEmpty)
    }

    @Test("A scope that fails to close does not fail the import")
    func closeFailureDoesNotFailTheImport() async throws {
        let driver = SessionScopeDriver()
        driver.closeError = ScopeRefusal()

        let run = try await runImport(ScriptedImportPlugin(statements: ["INSERT INTO courses VALUES (1)"]), on: driver)

        #expect(try run.result.get().executedStatements == 1)
        #expect(driver.events.last == "close")
    }

    @Test("A failure after the server committed the transaction says nothing was rolled back")
    func committedTransactionFailureCarriesTheNote() async throws {
        let failing = "INSERT INTO courses VALUES ('0000-00-00')"
        let driver = SessionScopeDriver()
        driver.transactionState = .idle
        driver.statesAfter = ["BEGIN": .inTransaction, "DROP TABLE IF EXISTS courses": .idle]
        driver.failingStatements = [failing]

        let run = try await runImport(
            ScriptedImportPlugin(statements: ["DROP TABLE IF EXISTS courses", failing]),
            on: driver
        )

        guard case .statementFailed(let statement, let line, let underlying)? = run.error as? PluginImportError else {
            Issue.record("Expected statementFailed, got \(String(describing: run.error))")
            return
        }
        #expect(statement == failing)
        #expect(line == 2)
        #expect(underlying.localizedDescription == SessionScopeDriver.failure + "\n" + ImportCommittedTransactionError.note)
        #expect(driver.events == ["open", "BEGIN", "DROP TABLE IF EXISTS courses", failing, "close"])
        #expect(run.service.state.transactionOutcome == .committedBeforeRollback)
    }

    /// A deadlock rolls the transaction back on the server, and the session then reads exactly as after a commit, so
    /// the failure carries no claim either way.
    @Test("A failure that ended the transaction on the server carries no note")
    func serverEndedTransactionCarriesNoNote() async throws {
        let failing = "INSERT INTO courses VALUES (2)"
        let driver = SessionScopeDriver()
        driver.transactionState = .idle
        driver.statesAfter = ["BEGIN": .inTransaction, failing: .idle]
        driver.failingStatements = [failing]

        let run = try await runImport(
            ScriptedImportPlugin(statements: ["INSERT INTO courses VALUES (1)", failing]),
            on: driver
        )

        guard case .statementFailed(_, let line, let underlying)? = run.error as? PluginImportError else {
            Issue.record("Expected statementFailed, got \(String(describing: run.error))")
            return
        }
        #expect(line == 2)
        #expect(underlying.localizedDescription == SessionScopeDriver.failure)
        #expect(driver.events == ["open", "BEGIN", "INSERT INTO courses VALUES (1)", failing, "close"])
        #expect(run.service.state.transactionOutcome == .endedByServer)
    }
}

@MainActor
struct ImportCommittedTransactionErrorTests {
    private struct DatabaseMessage: LocalizedError {
        let errorDescription: String?
    }

    @Test("A statement failure keeps its statement and line, and the alert shows the note under the reason")
    func statementFailureKeepsItsShape() throws {
        let original = PluginImportError.statementFailed(
            statement: "INSERT INTO courses VALUES ('0000-00-00')",
            line: 8_264,
            underlyingError: DatabaseMessage(errorDescription: "[1292] Incorrect date value")
        )

        let noted = ImportCommittedTransactionError.noting(original)

        guard case .statementFailed(let statement, let line, let underlying)? = noted as? PluginImportError else {
            Issue.record("Expected statementFailed, got \(noted)")
            return
        }
        #expect(statement == "INSERT INTO courses VALUES ('0000-00-00')")
        #expect(line == 8_264)
        #expect(underlying.localizedDescription == "[1292] Incorrect date value\n" + ImportCommittedTransactionError.note)
        let text = TransferResultAlert.importFailureText(for: noted)
        #expect(text.hasPrefix("Failed at line 8264. [1292] Incorrect date value"))
        #expect(text.contains(ImportCommittedTransactionError.note))
    }

    @Test("Any other failure carries the note under its own message")
    func otherFailureCarriesTheNote() {
        let original = PluginImportError.importFailed("disk full")

        let noted = ImportCommittedTransactionError.noting(original)

        #expect(noted.localizedDescription == original.localizedDescription + "\n" + ImportCommittedTransactionError.note)
    }

    /// Under `autocommit = 0` the rollback still undoes what ran after the DDL, so the note never says all of it stayed.
    @Test("The note says only some of what ran before the failure was kept")
    func noteSaysSomeWasKept() {
        #expect(
            ImportCommittedTransactionError.note
                == "The rollback did not undo everything. A statement in the file, such as COMMIT, CREATE, ALTER or "
                + "DROP, committed the import's transaction as it ran, so some of the statements before the failure "
                + "were kept."
        )
    }

    @Test("A cancel stays a cancel")
    func cancelIsUntouched() {
        #expect(ImportCommittedTransactionError.noting(PluginImportCancellationError()) is PluginImportCancellationError)
        #expect(ImportCommittedTransactionError.noting(CancellationError()) is CancellationError)
    }
}
