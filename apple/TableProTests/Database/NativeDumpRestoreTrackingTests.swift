//
//  NativeDumpRestoreTrackingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

private final class ReadingDumpRunner: NativeDumpRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var read: Int64?
    private var continuation: CheckedContinuation<NativeDumpRunResult, Never>?
    private var buffered: NativeDumpRunResult?
    private(set) var cancelCount = 0

    init(reportsReads: Bool) {
        read = reportsReads ? 0 : nil
    }

    var bytesRead: Int64? { lock.withLock { read } }

    func advance(to bytes: Int64) {
        lock.withLock { read = bytes }
    }

    func start() throws {}

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    var result: NativeDumpRunResult {
        get async {
            await withCheckedContinuation { continuation in
                let ready: NativeDumpRunResult? = lock.withLock {
                    if let buffered {
                        self.buffered = nil
                        return buffered
                    }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    func finish(_ outcome: NativeDumpRunResult) {
        let waiting: CheckedContinuation<NativeDumpRunResult, Never>? = lock.withLock {
            guard let continuation else {
                buffered = outcome
                return nil
            }
            self.continuation = nil
            return continuation
        }
        waiting?.resume(returning: outcome)
    }
}

@MainActor
private final class CompletionLog {
    var completions: [OperationCompletion] = []
}

// A restore was never reported when it ended, and Quit could not name one that was running.
@MainActor
struct NativeDumpRestoreTrackingTests {
    private let connection = TestFixtures.makeConnection(name: "Prod", database: "sales", type: .postgresql)

    private let job = NativeDumpJob.process(
        NativeDumpCommand(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:],
            stderrByteCap: 64_000
        )
    )

    private func service(
        runner: ReadingDumpRunner,
        registry: RunningWorkRegistry,
        log: CompletionLog
    ) -> NativeDumpService {
        NativeDumpService(
            kind: .restore,
            runningWork: registry,
            reportCompletion: { log.completions.append($0) },
            runnerFactory: { _ in runner }
        )
    }

    private func dumpFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-tracking-\(UUID().uuidString).sql")
        try Data(repeating: 0x20, count: bytes).write(to: url)
        return url
    }

    @Test("A finished restore leaves the registry and reports success on its connection and database")
    func successIsReported() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let log = CompletionLog()
        let runner = ReadingDumpRunner(reportsReads: false)
        let service = service(runner: runner, registry: registry, log: log)

        service.trackRestore(of: "sales", on: connection)
        let running = registry.items(in: .connection(connection.id))
        try service.run(job: job, database: "sales", fileURL: URL(fileURLWithPath: "/tmp/restore-success.sql"))
        runner.finish(.init(exitCode: 0, stderr: "", wasCancelled: false))
        try await waitUntil { !log.completions.isEmpty }

        #expect(running.count == 1)
        #expect(running.first?.kind == .restore)
        #expect(running.first?.subject == "sales")
        #expect(running.first?.connectionName == "Prod")
        #expect(registry.items(in: .app).isEmpty)
        let completion = try #require(log.completions.first)
        #expect(log.completions.count == 1)
        #expect(completion.kind == .restore)
        #expect(completion.owner == .connection(connection.id))
        #expect(completion.connectionName == "Prod")
        #expect(completion.databaseName == "sales")
        #expect(completion.outcome == .succeeded(OperationSummary()))
    }

    @Test("A failed restore reports the tool's message and leaves the registry")
    func failureIsReported() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let log = CompletionLog()
        let runner = ReadingDumpRunner(reportsReads: false)
        let service = service(runner: runner, registry: registry, log: log)

        service.trackRestore(of: "sales", on: connection)
        try service.run(job: job, database: "sales", fileURL: URL(fileURLWithPath: "/tmp/restore-failure.sql"))
        runner.finish(.init(exitCode: 1, stderr: "FATAL: connection refused", wasCancelled: false))
        try await waitUntil { !log.completions.isEmpty }

        #expect(log.completions.first?.outcome == .failed(reason: "FATAL: connection refused"))
        #expect(registry.items(in: .app).isEmpty)
    }

    @Test("Cancelling through the registry stops the tool and reports a cancel, not a failure")
    func registryCancelIsReportedAsCancelled() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let log = CompletionLog()
        let runner = ReadingDumpRunner(reportsReads: false)
        let service = service(runner: runner, registry: registry, log: log)

        service.trackRestore(of: "sales", on: connection)
        try service.run(job: job, database: "sales", fileURL: URL(fileURLWithPath: "/tmp/restore-cancel.sql"))
        registry.cancel(registry.items(in: .connection(connection.id)))

        #expect(runner.cancelCount == 1)
        #expect(service.state == .cancelling)
        runner.finish(.init(exitCode: -15, stderr: "", wasCancelled: true))
        try await waitUntil { !log.completions.isEmpty }

        #expect(log.completions.first?.outcome == .cancelled)
        #expect(registry.items(in: .app).isEmpty)
    }

    @Test("A restore that cannot start is reported as failed and leaves the registry")
    func startFailureIsReported() async throws {
        let registry = RunningWorkRegistry(providers: [])
        let log = CompletionLog()
        let service = service(runner: ReadingDumpRunner(reportsReads: false), registry: registry, log: log)
        let unknown = TestFixtures.makeConnection(name: "Odd", type: DatabaseType(rawValue: "tablepro-tests-no-dump"))

        await #expect(throws: NativeDumpError.unsupportedDatabase) {
            try await service.start(
                connection: unknown,
                database: "sales",
                fileURL: URL(fileURLWithPath: "/tmp/restore-unsupported.sql")
            )
        }

        #expect(log.completions.first?.outcome == .failed(reason: NativeDumpError.unsupportedDatabase.localizedDescription))
        #expect(registry.items(in: .app).isEmpty)
    }

    @Test("A dump fed through standard input reports how far the tool has read it")
    func standardInputDrivesTheBar() async throws {
        let file = try dumpFile(bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = ReadingDumpRunner(reportsReads: true)
        let service = service(runner: runner, registry: RunningWorkRegistry(providers: []), log: CompletionLog())

        try service.run(job: job, database: "sales", fileURL: file)
        #expect(service.state == .running(database: "sales", fileURL: file, bytesProcessed: 0, totalBytes: 1_000))

        runner.advance(to: 400)
        try await waitUntil {
            service.state == .running(database: "sales", fileURL: file, bytesProcessed: 400, totalBytes: 1_000)
        }
        runner.finish(.init(exitCode: 0, stderr: "", wasCancelled: false))
    }

    @Test("A tool that opens the file itself leaves the bar indeterminate")
    func unreadableOffsetStaysIndeterminate() throws {
        let file = try dumpFile(bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = ReadingDumpRunner(reportsReads: false)
        let service = service(runner: runner, registry: RunningWorkRegistry(providers: []), log: CompletionLog())

        try service.run(job: job, database: "sales", fileURL: file)

        #expect(service.state == .running(database: "sales", fileURL: file, bytesProcessed: 0, totalBytes: nil))
        runner.finish(.init(exitCode: 0, stderr: "", wasCancelled: false))
    }
}
