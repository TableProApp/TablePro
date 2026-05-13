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

    @Test("environment is restricted to a known allowlist plus libpq vars")
    func environmentIsMinimal() {
        let command = PostgresDumpService.buildCommand(
            kind: .backup,
            executable: URL(fileURLWithPath: "/usr/bin/pg_dump"),
            effective: connection(sslMode: .required),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/x.dump"),
            password: "s3cret"
        )
        let allowed: Set<String> = [
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL",
            "PGPASSWORD", "PGSSLMODE"
        ]
        let unexpected = Set(command.environment.keys).subtracting(allowed)
        #expect(unexpected.isEmpty, "unexpected env keys leaked through: \(unexpected)")
    }

    /// Returns the argument immediately following `flag` in the arg list.
    private func slice(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

// MARK: - Fake Runner

private final class FakeDumpRunner: PostgresDumpRunner, @unchecked Sendable {
    private(set) var startedCommand: PostgresDumpCommand?
    private(set) var cancelCount: Int = 0
    private var continuation: CheckedContinuation<PostgresDumpRunResult, Never>?
    private var bufferedResult: PostgresDumpRunResult?
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
                lock.lock()
                if let buffered = bufferedResult {
                    bufferedResult = nil
                    lock.unlock()
                    continuation.resume(returning: buffered)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ outcome: PostgresDumpRunResult) {
        lock.lock()
        if let continuation = self.continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            bufferedResult = outcome
            lock.unlock()
        }
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
        let updates = service.stateUpdates()

        #expect(service.state == .idle)
        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-success.dump"),
            totalBytesEstimate: 1_000
        )

        if case .running(let db, _, _, let total) = service.state {
            #expect(db == "sales")
            #expect(total == 1_000)
        } else {
            Issue.record("expected running, got \(service.state)")
        }

        runner.finish(.init(exitCode: 0, stderr: "", wasCancelled: false))
        let finalState = try await firstMatching(updates) { if case .finished = $0 { return true }; return false }

        if case .finished(let db, _, _) = finalState {
            #expect(db == "sales")
        } else {
            Issue.record("expected finished, got \(finalState)")
        }
    }

    @Test("non-zero exit transitions to failed and surfaces stderr")
    func failedRun() async throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .restore, runnerFactory: { runner })
        let updates = service.stateUpdates()

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-failed.dump")
        )

        runner.finish(.init(exitCode: 1, stderr: "FATAL: connection refused", wasCancelled: false))
        let finalState = try await firstMatching(updates) { if case .failed = $0 { return true }; return false }

        if case .failed(let message) = finalState {
            #expect(message == "FATAL: connection refused")
        } else {
            Issue.record("expected failed, got \(finalState)")
        }
    }

    @Test("cancel transitions running -> cancelling -> cancelled")
    func cancelRun() async throws {
        let runner = FakeDumpRunner()
        let service = PostgresDumpService(kind: .backup, runnerFactory: { runner })
        let updates = service.stateUpdates()

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-cancel.dump")
        )

        service.cancel()
        #expect(service.state == .cancelling)
        #expect(runner.cancelCount == 1)

        runner.finish(.init(exitCode: -15, stderr: "", wasCancelled: true))
        let finalState = try await firstMatching(updates) { $0 == .cancelled }
        #expect(finalState == .cancelled)
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
        let updates = service.stateUpdates()

        try service.run(
            command: fakeCommand(),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/test-emptyerr.dump")
        )
        runner.finish(.init(exitCode: 42, stderr: "", wasCancelled: false))
        let finalState = try await firstMatching(updates) { if case .failed = $0 { return true }; return false }

        if case .failed(let message) = finalState {
            #expect(message.contains("42"))
        } else {
            Issue.record("expected failed, got \(finalState)")
        }
    }

    private func firstMatching(
        _ stream: AsyncStream<PostgresDumpState>,
        where predicate: @Sendable (PostgresDumpState) -> Bool
    ) async throws -> PostgresDumpState {
        for await state in stream where predicate(state) {
            return state
        }
        Issue.record("state stream ended before predicate matched")
        return .idle
    }
}
