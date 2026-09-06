//
//  NativeDumpBatchTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Stands in for `NativeDumpService` so the sequencing, the per-item outcomes and the cancel path
/// can be driven without a live connection or a subprocess.
@MainActor
private final class FakeDumpService: NativeDumpRunning {
    private(set) var startedDatabases: [String] = []
    private(set) var startedScopes: [NativeDumpScope] = []
    private(set) var cancelCount = 0

    /// Keyed by database, so a test can make exactly one item of a batch fail.
    var behaviour: [String: NativeDumpState] = [:]
    var defaultBehaviour: NativeDumpState = .finished(
        database: "", fileURL: URL(fileURLWithPath: "/tmp/x"), bytesProcessed: 10
    )
    var startError: Error?
    /// Fires as the item starts, before any state is yielded, so a test can cancel at exactly the
    /// point a user would rather than racing the run.
    var onStart: (@MainActor () -> Void)?

    private var observers: [AsyncStream<NativeDumpState>.Continuation] = []

    func stateUpdates() -> AsyncStream<NativeDumpState> {
        let (stream, continuation) = AsyncStream<NativeDumpState>.makeStream()
        observers.append(continuation)
        continuation.yield(.idle)
        return stream
    }

    func start(
        connection: DatabaseConnection,
        database: String,
        fileURL: URL,
        scope: NativeDumpScope,
        formatId: String?,
        totalBytesEstimate: Int64?
    ) async throws {
        startedDatabases.append(database)
        startedScopes.append(scope)
        onStart?()
        if let startError { throw startError }
        let terminal = behaviour[database] ?? substituted(defaultBehaviour, database: database, fileURL: fileURL)
        for observer in observers {
            observer.yield(.running(database: database, fileURL: fileURL, bytesProcessed: 5, totalBytes: nil))
            observer.yield(terminal)
        }
    }

    private func substituted(_ state: NativeDumpState, database: String, fileURL: URL) -> NativeDumpState {
        guard case .finished(_, _, let bytes) = state else { return state }
        return .finished(database: database, fileURL: fileURL, bytesProcessed: bytes)
    }

    func cancel() {
        cancelCount += 1
        for observer in observers {
            observer.yield(.cancelled)
        }
    }
}

@Suite("Native dump batch", .serialized)
@MainActor
struct NativeDumpBatchTests {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tp-batch-tests")

    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            host: "db.example.com",
            port: 5_432,
            database: "sales",
            username: "alice",
            type: .postgresql,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration()
        )
    }

    private func items(_ databases: [String], in directory: URL) -> [NativeDumpBatchItem] {
        NativeDumpDestination.plan(
            databases: databases, in: directory, timestamp: "t", fileExtension: "dump"
        ).map {
            NativeDumpBatchItem(database: $0.database, scope: .wholeDatabase, destination: $0.url)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Every database is written, in order, one at a time")
    func runsEveryItemInOrder() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeDumpService()
        let batch = NativeDumpBatch(makeService: { service }, estimateSize: { _, _ in nil })

        await batch.run(
            connection: connection(),
            items: items(["sales", "billing", "analytics"], in: directory),
            formatId: nil
        )

        #expect(service.startedDatabases == ["sales", "billing", "analytics"])
        #expect(batch.state.outcomes.map(\.database) == ["sales", "billing", "analytics"])
        #expect(batch.state.outcomes.allSatisfy { $0.succeeded })
        #expect(!batch.state.isRunning)
    }

    /// `TableTransferService` and `ExportService` both abort on the first error because they write
    /// one artifact. A backup of three databases writes three independent files, so losing the
    /// third because the second was unreadable helps nobody.
    @Test("A failed database does not stop the ones after it")
    func continuesPastAFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeDumpService()
        service.behaviour["billing"] = .failed(message: "permission denied", targetMayBeModified: false)
        let batch = NativeDumpBatch(makeService: { service }, estimateSize: { _, _ in nil })

        await batch.run(
            connection: connection(),
            items: items(["sales", "billing", "analytics"], in: directory),
            formatId: nil
        )

        #expect(service.startedDatabases == ["sales", "billing", "analytics"])
        #expect(batch.state.outcomes.count == 3)
        #expect(batch.state.outcomes[0].succeeded)
        #expect(!batch.state.outcomes[1].succeeded)
        #expect(batch.state.outcomes[2].succeeded)
        if case .failed(let message) = batch.state.outcomes[1].result {
            #expect(message == "permission denied")
        } else {
            Issue.record("expected a failure outcome, got \(batch.state.outcomes[1].result)")
        }
    }

    /// A backup that cannot even be started is still an outcome. Reporting only what ran would let
    /// a run of three report two and look complete.
    @Test("A database that cannot be started is reported, not skipped")
    func recordsStartFailures() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeDumpService()
        service.startError = NativeDumpError.noSession
        let batch = NativeDumpBatch(makeService: { service }, estimateSize: { _, _ in nil })

        await batch.run(connection: connection(), items: items(["sales"], in: directory), formatId: nil)

        #expect(batch.state.outcomes.count == 1)
        #expect(!batch.state.outcomes[0].succeeded)
    }

    @Test("Cancelling stops the run and reports the databases it never reached")
    func cancelStopsTheBatch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeDumpService()
        let batch = NativeDumpBatch(makeService: { service }, estimateSize: { _, _ in nil })
        service.onStart = { [weak batch] in batch?.cancel() }

        await batch.run(
            connection: connection(),
            items: items(["sales", "billing"], in: directory),
            formatId: nil
        )

        #expect(service.startedDatabases == ["sales"], "the second database must never be started")
        #expect(service.cancelCount == 1)
        #expect(batch.state.outcomes.count == 2, "the database never reached is still reported")
        #expect(batch.state.outcomes.allSatisfy { !$0.succeeded })
    }

    @Test("Each item carries its own scope through to the service")
    func scopesReachTheService() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeDumpService()
        let batch = NativeDumpBatch(makeService: { service }, estimateSize: { _, _ in nil })

        let plan = NativeDumpDestination.plan(
            databases: ["sales", "billing"], in: directory, timestamp: "t", fileExtension: "dump"
        )
        await batch.run(
            connection: connection(),
            items: [
                NativeDumpBatchItem(
                    database: "sales",
                    scope: .objects([NativeDumpObject(name: "orders", schema: "app")]),
                    destination: plan[0].url
                ),
                NativeDumpBatchItem(database: "billing", scope: .wholeDatabase, destination: plan[1].url)
            ],
            formatId: nil
        )

        #expect(service.startedScopes.count == 2)
        #expect(!service.startedScopes[0].isWholeDatabase)
        #expect(service.startedScopes[1].isWholeDatabase)
    }
}
