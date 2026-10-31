//
//  NativeDumpIsolatedImportTests.swift
//  TableProTests
//
//  A Parquet folder's schema.sql is untrusted: with DuckDB 1.5 a `COPY ... TO` in it writes any file the user can.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class IsolatedRestoreDriver: PluginDriverStub, @unchecked Sendable {
    enum Import {
        case succeeds
        case fails(String)
        case waitsForCancel
    }

    private let lock = NSLock()
    private var log: [String] = []
    private let importBehavior: Import
    private let failingStatement: String?
    let importStarted = AsyncStream<Void>.makeStream()
    private let cancelled = AsyncStream<Void>.makeStream()

    init(import importBehavior: Import, failingStatement: String? = nil) {
        self.importBehavior = importBehavior
        self.failingStatement = failingStatement
    }

    var calls: [String] { lock.withLock { log } }

    func importExportedDatabase(from folder: URL, into file: URL) async throws {
        lock.withLock { log.append("import \(folder.path) into \(file.path)") }
        importStarted.continuation.yield()
        switch importBehavior {
        case .succeeds:
            return
        case .fails(let message):
            throw DriverStubError(message: message)
        case .waitsForCancel:
            let signal = cancelled
            try await withTaskCancellationHandler {
                for await _ in signal.stream { break }
                throw CancellationError()
            } onCancel: {
                signal.continuation.yield()
            }
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { log.append(query) }
        if query == failingStatement { throw DriverStubError(message: "Constraint Error: Violates foreign key constraint") }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}
}

// A driver built before the requirement existed gets PluginKit's default.
private final class DriverWithoutIsolatedImport: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var statements: [String] { lock.withLock { log } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { log.append(query) }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}
}

private struct DriverStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Suite("Native dump isolated import", .serialized)
@MainActor
struct NativeDumpIsolatedImportTests {
    private let folder = URL(fileURLWithPath: "/tmp/sales-export's", isDirectory: true)

    private var parquet: NativeDumpDescriptor.EngineStatements {
        get throws {
            try #require(NativeDumpRegistry.descriptor(for: .duckdb, formatId: "parquet")?.engineStatements)
        }
    }

    private func request(_ connection: DatabaseConnection, catalog: String?) -> NativeDumpDescriptor.Request {
        NativeDumpDescriptor.Request(
            connection: connection,
            database: "live",
            fileURL: folder,
            password: nil,
            currentCatalog: catalog
        )
    }

    private func job(for connection: DatabaseConnection) throws -> NativeDumpStatementJob {
        try NativeDumpService.statementJob(
            kind: .restore,
            engine: parquet,
            request: request(connection, catalog: "live"),
            alias: "bak1",
            scope: DatabaseScope(connectionId: connection.id, database: "live", schema: nil)
        )
    }

    private func install(_ driver: some PluginDatabaseDriver) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: "live", type: .duckdb)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "live"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func restore(_ job: NativeDumpStatementJob) async throws -> NativeDumpState {
        let service = NativeDumpService(kind: .restore)
        let states = service.stateUpdates()
        try service.run(job: .statements(job), database: "live", fileURL: folder)
        return await Self.terminal(states)
    }

    private static func terminal(_ states: AsyncStream<NativeDumpState>) async -> NativeDumpState {
        for await state in states {
            switch state {
            case .finished, .failed, .cancelled: return state
            case .idle, .running, .cancelling: continue
            }
        }
        return .idle
    }

    private static func stagingDirectories() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        return Set(names.filter { $0.hasPrefix("tablepro-restore-") })
    }

    @Test("A Parquet restore stages a private file and restores it, never the folder's SQL")
    func parquetRestoreJob() throws {
        let connection = TestFixtures.makeConnection(database: "live", type: .duckdb)
        let job = try job(for: connection)
        defer { NativeDumpJob.statements(job).discardTemporaryFiles() }
        let isolated = try #require(job.isolatedImport)
        let file = isolated.file.path

        #expect(isolated.archive == folder)
        #expect(isolated.file.deletingLastPathComponent().path == isolated.directory.path)
        #expect(isolated.file.pathExtension == "duckdb")
        let permissions = try FileManager.default.attributesOfItem(atPath: isolated.directory.path)[.posixPermissions]
        #expect((permissions as? NSNumber)?.intValue == 0o700)
        #expect(job.statements == [
            "ATTACH '\(file)' AS \"bak1\" (READ_ONLY)",
            "COPY FROM DATABASE \"bak1\" TO \"live\" (SCHEMA)",
            "COPY FROM DATABASE \"bak1\" TO \"live\" (DATA)",
            "DETACH \"bak1\"",
        ])
        #expect(!job.statements.contains { $0.contains("IMPORT") || $0.contains("sales-export") })
    }

    @Test("A job that never reaches a runner leaves no staging directory")
    func discardRemovesTheStagingDirectory() throws {
        let job = try job(for: TestFixtures.makeConnection(database: "live", type: .duckdb))
        let directory = try #require(job.isolatedImport?.directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        NativeDumpJob.statements(job).discardTemporaryFiles()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Without a catalog the job is refused before a staging directory exists")
    func noCatalogCreatesNothing() throws {
        let connection = TestFixtures.makeConnection(database: "live", type: .duckdb)
        let before = try Self.stagingDirectories()

        #expect(throws: NativeDumpError.engineStatementUnavailable) {
            try NativeDumpService.statementJob(
                kind: .restore,
                engine: parquet,
                request: request(connection, catalog: nil),
                alias: "bak1",
                scope: DatabaseScope(connectionId: connection.id, database: "live", schema: nil)
            )
        }
        #expect(try Self.stagingDirectories() == before)
    }

    @Test("A Parquet backup and a .duckdb restore run on the session with nothing staged")
    func otherJobsStageNothing() throws {
        let connection = TestFixtures.makeConnection(database: "live", type: .duckdb)
        let scope = DatabaseScope(connectionId: connection.id, database: "live", schema: nil)
        let file = try #require(NativeDumpRegistry.descriptor(for: .duckdb, formatId: "duckdb")?.engineStatements)

        let backup = try NativeDumpService.statementJob(
            kind: .backup, engine: parquet, request: request(connection, catalog: "live"), alias: "bak1", scope: scope
        )
        let fileRestore = try NativeDumpService.statementJob(
            kind: .restore, engine: file, request: request(connection, catalog: "live"), alias: "bak1", scope: scope
        )

        #expect(backup.isolatedImport == nil)
        #expect(backup.statements == ["EXPORT DATABASE '/tmp/sales-export''s' (FORMAT PARQUET)"])
        #expect(fileRestore.isolatedImport == nil)
    }

    @Test("The import runs before the session restores its file, and the staging directory goes")
    func importThenRestore() async throws {
        let driver = IsolatedRestoreDriver(import: .succeeds)
        let connection = install(driver)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let job = try job(for: connection)
        let isolated = try #require(job.isolatedImport)

        let state = try await restore(job)

        guard case .finished = state else {
            Issue.record("expected finished, got \(state)")
            return
        }
        #expect(driver.calls == ["import \(folder.path) into \(isolated.file.path)"] + job.statements)
        #expect(!FileManager.default.fileExists(atPath: isolated.directory.path))
    }

    @Test("A folder the isolated instance refuses fails the restore with the cause and an untouched target")
    func refusedFolderLeavesTheTargetAlone() async throws {
        let refusal = """
            Permission Error: Cannot access file "/Users/me/.zshrc" - file system operations are disabled by configuration
            """
        let driver = IsolatedRestoreDriver(import: .fails(refusal))
        let connection = install(driver)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let job = try job(for: connection)
        let isolated = try #require(job.isolatedImport)

        let state = try await restore(job)

        guard case .failed(let message, let targetMayBeModified) = state else {
            Issue.record("expected failed, got \(state)")
            return
        }
        #expect(message.contains("this database was not changed"))
        #expect(message.contains(refusal))
        #expect(!targetMayBeModified)
        #expect(driver.calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: isolated.directory.path))
    }

    @Test("Cancel during the import stops it before the session runs anything")
    func cancelDuringImport() async throws {
        let driver = IsolatedRestoreDriver(import: .waitsForCancel)
        let connection = install(driver)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let job = try job(for: connection)
        let isolated = try #require(job.isolatedImport)
        let service = NativeDumpService(kind: .restore)
        let states = service.stateUpdates()

        try service.run(job: .statements(job), database: "live", fileURL: folder)
        for await _ in driver.importStarted.stream { break }
        service.cancel()
        let state = await Self.terminal(states)

        #expect(state == .cancelled)
        #expect(driver.calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: isolated.directory.path))
    }

    @Test("A driver without the isolated import refuses the folder instead of running it on the session")
    func driverWithoutTheRequirement() async throws {
        let driver = DriverWithoutIsolatedImport()
        let connection = install(driver)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let job = try job(for: connection)

        let state = try await restore(job)

        guard case .failed(let message, let targetMayBeModified) = state else {
            Issue.record("expected failed, got \(state)")
            return
        }
        #expect(message.contains(PluginDriverUnsupportedOperation.importExportedDatabase.localizedDescription))
        #expect(!targetMayBeModified)
        #expect(driver.statements.isEmpty)
    }

    @Test("A copy that fails after the import may have changed the target, and the alias is detached")
    func copyFailureAfterImport() async throws {
        let driver = IsolatedRestoreDriver(
            import: .succeeds,
            failingStatement: "COPY FROM DATABASE \"bak1\" TO \"live\" (DATA)"
        )
        let connection = install(driver)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let job = try job(for: connection)
        let isolated = try #require(job.isolatedImport)

        let state = try await restore(job)

        guard case .failed(_, let targetMayBeModified) = state else {
            Issue.record("expected failed, got \(state)")
            return
        }
        #expect(targetMayBeModified)
        #expect(driver.calls.last == "DETACH \"bak1\"")
        #expect(!FileManager.default.fileExists(atPath: isolated.directory.path))
    }
}
