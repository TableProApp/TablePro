//
//  ImportServiceRunningWorkTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private struct StatementRefused: Error {}

private final class RunningWorkDriver: PluginDriverStub, @unchecked Sendable {
    var transactionState: PluginSessionTransactionState = .unknown
    var statesAfter: [String: PluginSessionTransactionState] = [:]
    var failingStatements: Set<String> = []
    var transactional = true

    var supportsTransactions: Bool { transactional }

    func execute(query: String) async throws -> PluginQueryResult {
        if let next = statesAfter[query] { transactionState = next }
        if failingStatements.contains(query) { throw StatementRefused() }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}

    func sessionTransactionState() async -> PluginSessionTransactionState {
        transactionState
    }
}

// Opens a transaction, runs `before`, lets the test look at the run, then runs `after` and commits.
private final class ProbedImportPlugin: ImportFormatPlugin {
    static let pluginName = "Probed Import"
    static let pluginVersion = "1.0"
    static let pluginDescription = "An import format a test can look inside"
    static let formatId = "tablepro-tests-probed-import"
    static let formatDisplayName = "Probed"
    static let acceptedFileExtensions = ["sql"]
    static let iconName = "doc"
    static let requiresTargetTable = true

    private let before: [String]
    private let after: [String]
    private let probe: @MainActor () async -> Void

    required init() {
        before = []
        after = []
        probe = {}
    }

    init(before: [String] = [], after: [String] = [], probe: @escaping @MainActor () async -> Void) {
        self.before = before
        self.after = after
        self.probe = probe
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        try await sink.beginTransaction()
        do {
            for statement in before {
                try await sink.execute(statement: statement, line: 1)
            }
            await probe()
            for statement in after {
                try progress.checkCancellation()
                try await sink.execute(statement: statement, line: 1)
            }
            try progress.checkCancellation()
            try await sink.commitTransaction()
        } catch {
            try? await sink.rollbackTransaction()
            throw error
        }
        return PluginImportResult(executedStatements: before.count + after.count, executionTime: 0)
    }
}

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

@MainActor
private final class RunLook {
    var work: [RunningWork] = []
    var rollsBackOnStop: Bool?
}

// Quit, Close and Disconnect can only name an import the registry knows about, and only until it ends.
@MainActor
struct ImportServiceRunningWorkTests {
    private let connection = TestFixtures.makeConnection(name: "Shop", database: "school", type: .mysql)

    private func runImport(
        driver: RunningWorkDriver,
        registry: RunningWorkRegistry,
        makePlugin: (ImportService) -> ProbedImportPlugin
    ) async throws -> Result<PluginImportResult, any Error> {
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "school"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let service = ImportService(
            connection: connection,
            historyRecorder: DiscardingHistory(),
            gate: AlwaysAllowGate(),
            runningWork: registry
        )
        let formatId = "\(ProbedImportPlugin.formatId)-\(UUID().uuidString)"
        PluginManager.shared.importPlugins[formatId] = makePlugin(service)
        defer { PluginManager.shared.importPlugins[formatId] = nil }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-work-import-\(UUID().uuidString)")
            .appendingPathExtension("sql")
        try Data("SELECT 1;\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            return .success(try await service.importFile(
                from: file,
                sourceName: "courses.sql",
                formatId: formatId,
                encoding: .utf8,
                scope: DatabaseScope(connectionId: connection.id, database: "school", schema: nil)
            ))
        } catch {
            return .failure(error)
        }
    }

    @Test("A running import is named by its file and ends with the import")
    func successRegistersThenEnds() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let look = RunLook()

        let result = try await runImport(driver: RunningWorkDriver(), registry: registry) { service in
            ProbedImportPlugin(after: ["INSERT INTO courses VALUES (1)"]) {
                look.work = registry.items(in: .connection(connection.id))
                try? await waitUntil(timeout: .seconds(5)) { service.state.rollsBackOnStop }
                look.rollsBackOnStop = service.state.rollsBackOnStop
            }
        }

        _ = try result.get()
        #expect(look.work.count == 1)
        #expect(look.work.first?.kind == .dataImport)
        #expect(look.work.first?.subject == "courses.sql")
        #expect(look.work.first?.connectionName == "Shop")
        #expect(look.rollsBackOnStop == true, "inside its own transaction a Stop takes everything back")
        #expect(registry.items(in: .app).isEmpty)
    }

    @Test("A failed import leaves nothing registered")
    func failureEnds() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let driver = RunningWorkDriver()
        driver.failingStatements = ["INSERT INTO courses VALUES ('bad')"]
        let look = RunLook()

        let result = try await runImport(driver: driver, registry: registry) { _ in
            ProbedImportPlugin(after: ["INSERT INTO courses VALUES ('bad')"]) {
                look.work = registry.items(in: .app)
            }
        }

        guard case .failure = result else {
            Issue.record("expected the import to fail")
            return
        }
        #expect(look.work.count == 1)
        #expect(registry.items(in: .app).isEmpty)
    }

    @Test("Cancelling through the registry stops the import, which then leaves the registry")
    func registryCancelStopsTheImport() async throws {
        let registry = RunningWorkRegistry(providers: [])

        let result = try await runImport(driver: RunningWorkDriver(), registry: registry) { _ in
            ProbedImportPlugin(after: ["INSERT INTO courses VALUES (1)"]) {
                registry.cancel(registry.items(in: .connection(connection.id)))
            }
        }

        guard case .failure(let error) = result else {
            Issue.record("expected the import to stop")
            return
        }
        #expect(error is PluginImportCancellationError)
        #expect(registry.items(in: .app).isEmpty)
    }

    // The probe runs after every update the sink queued before it, so an unfounded promise would already show.
    @Test("Inside the user's own transaction a Stop promises no rollback")
    func usersTransactionPromisesNoRollback() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let driver = RunningWorkDriver()
        driver.transactionState = .inTransaction
        let look = RunLook()

        let result = try await runImport(driver: driver, registry: registry) { service in
            ProbedImportPlugin(after: ["INSERT INTO courses VALUES (1)"]) {
                look.rollsBackOnStop = service.state.rollsBackOnStop
            }
        }

        _ = try result.get()
        #expect(look.rollsBackOnStop == false)
    }

    @Test("On an engine without transactions a Stop promises no rollback")
    func nonTransactionalEnginePromisesNoRollback() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let driver = RunningWorkDriver()
        driver.transactional = false
        let look = RunLook()

        let result = try await runImport(driver: driver, registry: registry) { service in
            ProbedImportPlugin(after: ["INSERT INTO courses VALUES (1)"]) {
                look.rollsBackOnStop = service.state.rollsBackOnStop
            }
        }

        _ = try result.get()
        #expect(look.rollsBackOnStop == false)
    }

    @Test("Once the file commits on its own, a Stop no longer takes everything back")
    func earlyCommitEndsTheRollback() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let driver = RunningWorkDriver()
        driver.transactionState = .idle
        driver.statesAfter = ["BEGIN": .inTransaction, "DROP TABLE IF EXISTS courses": .idle]
        let look = RunLook()

        let result = try await runImport(driver: driver, registry: registry) { service in
            ProbedImportPlugin(before: ["DROP TABLE IF EXISTS courses"]) {
                try? await waitUntil(timeout: .seconds(2)) { !service.state.rollsBackOnStop }
                look.rollsBackOnStop = service.state.rollsBackOnStop
            }
        }

        _ = try result.get()
        #expect(look.rollsBackOnStop == false)
    }
}
