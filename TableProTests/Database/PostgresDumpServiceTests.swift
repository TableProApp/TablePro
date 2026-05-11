//
//  PostgresDumpServiceTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("PostgresDumpService command construction")
struct PostgresDumpServiceCommandTests {
    private func connection(
        host: String = "db.example.com",
        port: Int = 5_432,
        username: String = "alice",
        sslMode: SSLMode = .disabled
    ) -> DatabaseConnection {
        var sslConfig = SSLConfiguration()
        sslConfig.mode = sslMode
        return DatabaseConnection(
            name: "Test",
            host: host,
            port: port,
            database: "sales",
            username: username,
            type: .postgresql,
            sshConfig: SSHConfiguration(),
            sslConfig: sslConfig
        )
    }

    @Test("backup command sets -Fc, host, port, username, -d, -f")
    func backupCommandShape() {
        let command = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/sales.dump"),
            password: "s3cret"
        )

        #expect(command.arguments.contains("-Fc"))
        #expect(command.arguments.contains("--no-password"))
        #expect(slice(after: "-h", in: command.arguments) == "db.example.com")
        #expect(slice(after: "-p", in: command.arguments) == "5432")
        #expect(slice(after: "-U", in: command.arguments) == "alice")
        #expect(slice(after: "-d", in: command.arguments) == "sales")
        #expect(slice(after: "-f", in: command.arguments) == "/tmp/sales.dump")
        #expect(command.environment["PGPASSWORD"] == "s3cret")
    }

    @Test("restore command sets --no-owner, --no-acl, -d, positional path")
    func restoreCommandShape() {
        let command = PostgresDumpService.buildCommand(
            kind: .restore,
            executable: URL(fileURLWithPath: "/usr/bin/pg_restore"),
            effective: connection(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/sales.dump"),
            password: "s3cret"
        )

        #expect(command.arguments.contains("--no-owner"))
        #expect(command.arguments.contains("--no-acl"))
        #expect(command.arguments.contains("--no-password"))
        #expect(!command.arguments.contains("-Fc"))
        #expect(slice(after: "-d", in: command.arguments) == "sales")
        #expect(command.arguments.last == "/tmp/sales.dump")
        #expect(!command.arguments.contains("-f"))
    }

    @Test("empty host falls back to 127.0.0.1")
    func hostFallback() {
        let command = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(host: ""),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/x.dump"),
            password: nil
        )
        #expect(slice(after: "-h", in: command.arguments) == "127.0.0.1")
    }

    @Test("empty username omits -U entirely")
    func usernameOmitted() {
        let command = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(username: ""),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/x.dump"),
            password: nil
        )
        #expect(!command.arguments.contains("-U"))
    }

    @Test("nil/empty password does not set PGPASSWORD")
    func passwordOptional() {
        let nilPw = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/x.dump"),
            password: nil
        )
        let emptyPw = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/x.dump"),
            password: ""
        )
        #expect(nilPw.environment["PGPASSWORD"] == nil)
        #expect(emptyPw.environment["PGPASSWORD"] == nil)
    }

    @Test("SSL mode maps to libpq PGSSLMODE values", arguments: [
        (SSLMode.disabled, nil as String?),
        (SSLMode.preferred, "prefer"),
        (SSLMode.required, "require"),
        (SSLMode.verifyCa, "verify-ca"),
        (SSLMode.verifyIdentity, "verify-full")
    ])
    func sslModeMapping(mode: SSLMode, expected: String?) {
        let command = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(sslMode: mode),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/x.dump"),
            password: nil
        )
        #expect(command.environment["PGSSLMODE"] == expected)
    }

    /// Returns the argument immediately following `flag` in the arg list.
    private func slice(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

// MARK: - Fake Runner

/// Test double for `PostgresDumpRunner` that lets tests drive the result.
private final class FakeDumpRunner: PostgresDumpRunner, @unchecked Sendable {
    private(set) var startedCommand: PostgresDumpCommand?
    private(set) var cancelCount: Int = 0
    private var continuation: CheckedContinuation<PostgresDumpRunResult, Never>?
    private let lock = NSLock()

    func start(_ command: PostgresDumpCommand) throws {
        startedCommand = command
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }

    var result: PostgresDumpRunResult {
        get async {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    /// Test driver: resolves the pending `result` await with the given outcome.
    func finish(_ outcome: PostgresDumpRunResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

@Suite("PostgresDumpService state machine", .serialized)
@MainActor
struct PostgresDumpServiceStateMachineTests {
    private func fakeCommand() -> PostgresDumpCommand {
        PostgresDumpCommand(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:],
            stderrByteCap: 64_000
        )
    }

    @Test("successful run transitions idle -> running -> finished")
    func successfulBackup() async throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .backup, runnerFactory: { runner })

        #expect(service.state == .idle)
        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-success.dump"),
            totalBytesEstimate: 1_000
        )

        // Now running
        if case .running(let db, _, _, let total) = service.state {
            #expect(db == "sales")
            #expect(total == 1_000)
        } else {
            Issue.record("expected running, got \(service.state)")
        }

        runner.finish(.init(exitCode: 0, stderr: "", wasCancelled: false))
        try await waitFor { if case .finished = service.state { return true }; return false }

        if case .finished(let db, _, _) = service.state {
            #expect(db == "sales")
        } else {
            Issue.record("expected finished, got \(service.state)")
        }
    }

    @Test("non-zero exit transitions to failed and surfaces stderr")
    func failedRun() async throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .restore, runnerFactory: { runner })

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-failed.dump")
        )

        runner.finish(.init(exitCode: 1, stderr: "FATAL: connection refused", wasCancelled: false))
        try await waitFor { if case .failed = service.state { return true }; return false }

        if case .failed(let message) = service.state {
            #expect(message == "FATAL: connection refused")
        } else {
            Issue.record("expected failed, got \(service.state)")
        }
    }

    @Test("cancel transitions running -> cancelling -> cancelled")
    func cancelRun() async throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .backup, runnerFactory: { runner })

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-cancel.dump")
        )

        service.cancel()
        #expect(service.state == .cancelling)
        #expect(runner.cancelCount == 1)

        runner.finish(.init(exitCode: -15, stderr: "", wasCancelled: true))
        try await waitFor { service.state == .cancelled }
        #expect(service.state == .cancelled)
    }

    @Test("calling run while already running throws alreadyRunning")
    func doubleRunThrows() throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .backup, runnerFactory: { runner })

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-double.dump")
        )

        #expect(throws: PostgresDumpError.alreadyRunning) {
            try service.run(
                command: fakeCommand(),
                database: "sales",
                fileURL: URL(fileURLWithPath: "/tmp/test-double-2.dump")
            )
        }
    }

    @Test("empty stderr falls back to a synthesized error message")
    func emptyStderrFallback() async throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .backup, runnerFactory: { runner })

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-emptyerr.dump")
        )
        runner.finish(.init(exitCode: 42, stderr: "", wasCancelled: false))
        try await waitFor { if case .failed = service.state { return true }; return false }

        if case .failed(let message) = service.state {
            #expect(message.contains("42"))
        } else {
            Issue.record("expected failed, got \(service.state)")
        }
    }

    /// Polls `condition` every 10ms up to 2 seconds.
    private func waitFor(_ condition: @MainActor @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("timed out waiting for condition")
    }
}
