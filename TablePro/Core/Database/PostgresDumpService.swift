//
//  PostgresDumpService.swift
//  TablePro
//
//  Consolidated backup + restore state machine for PostgreSQL connections.
//  The actual Process execution is delegated to a `DumpRunner` so the
//  state machine can be exercised in tests with a fake runner.
//

import Foundation
import Observation
import os
import TableProPluginKit

// MARK: - Public Types

/// What the service is doing: dump (back up) a database or restore a dump file.
enum PostgresDumpKind: Equatable, Sendable {
    case backup
    case restore
}

/// Observable state of a backup or restore.
enum PostgresDumpState: Equatable {
    case idle
    case running(database: String, fileURL: URL, bytesProcessed: Int64, totalBytes: Int64?)
    case cancelling
    case finished(database: String, fileURL: URL, bytesProcessed: Int64)
    case failed(message: String)
    case cancelled
}

enum PostgresDumpError: LocalizedError, Equatable {
    case binaryNotFound(name: String)
    case unsupportedDatabase
    case noSession
    case alreadyRunning
    case sourceUnreadable

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return String(
                format: String(localized: """
                    %@ was not found on this system. Install it with `brew install libpq` and \
                    link it, or set a custom path under Settings > Terminal > CLI Paths > %@.
                    """),
                name, name
            )
        case .unsupportedDatabase:
            return String(localized: "Dump operations are only supported for PostgreSQL and Redshift connections.")
        case .noSession:
            return String(localized: "Connect to the database before starting this operation.")
        case .alreadyRunning:
            return String(localized: "An operation is already running.")
        case .sourceUnreadable:
            return String(localized: "The selected backup file is not readable.")
        }
    }
}

/// Parameters for a single backup or restore command.
struct PostgresDumpCommand: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let stderrByteCap: Int
}

/// Captured terminal state of a finished/cancelled subprocess.
struct PostgresDumpRunResult: Equatable {
    let exitCode: Int32
    let stderr: String
    let wasCancelled: Bool
}

/// Spawns and supervises a single subprocess. Abstracted so the dump
/// state machine can be tested without launching real processes.
protocol PostgresDumpRunner: AnyObject {
    /// Launches the command. Throws synchronously if the binary can't be spawned.
    /// `result` returns the final outcome when the process exits.
    func start(_ command: PostgresDumpCommand) throws
    /// Sends SIGTERM. Safe to call multiple times.
    func cancel()
    /// Resolves once the process has terminated (normally or via cancel).
    var result: PostgresDumpRunResult { get async }
}

// MARK: - Service

@MainActor
@Observable
final class PostgresDumpService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PostgresDumpService")

    let kind: PostgresDumpKind
    private(set) var state: PostgresDumpState = .idle

    @ObservationIgnored private let runnerFactory: () -> any PostgresDumpRunner
    @ObservationIgnored private var runner: (any PostgresDumpRunner)?
    @ObservationIgnored private var byteSizeTask: Task<Void, Never>?

    /// Default initializer uses the real `Process`-backed runner.
    init(kind: PostgresDumpKind) {
        self.kind = kind
        self.runnerFactory = { ProcessPostgresDumpRunner() }
    }

    /// Test-friendly initializer that injects a custom runner factory.
    init(kind: PostgresDumpKind, runnerFactory: @escaping () -> any PostgresDumpRunner) {
        self.kind = kind
        self.runnerFactory = runnerFactory
    }

    /// Starts the operation. `fileURL` is the destination for `.backup` and
    /// the source for `.restore`. `totalBytesEstimate` enables a determinate
    /// progress bar (used by backup; restore stays indeterminate).
    ///
    /// This entry point resolves dependencies from app singletons
    /// (`DatabaseManager`, `ConnectionStorage`, `AppSettingsManager`,
    /// `CLICommandResolver`). Tests should use `run(command:database:fileURL:totalBytesEstimate:)`
    /// directly with a fake runner.
    func start(
        connection: DatabaseConnection,
        database: String,
        fileURL: URL,
        totalBytesEstimate: Int64? = nil
    ) async throws {
        if case .running = state { throw PostgresDumpError.alreadyRunning }
        if case .cancelling = state { throw PostgresDumpError.alreadyRunning }

        guard connection.type == .postgresql || connection.type == .redshift else {
            throw PostgresDumpError.unsupportedDatabase
        }

        let session = DatabaseManager.shared.session(for: connection.id)
        guard session?.isConnected == true else { throw PostgresDumpError.noSession }

        if kind == .restore {
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw PostgresDumpError.sourceUnreadable
            }
        }

        let effective = session?.effectiveConnection ?? connection
        let password = ConnectionStorage.shared.loadPassword(for: connection.id) ?? session?.cachedPassword

        let cliKey: String
        let binaryName: String
        switch kind {
        case .backup:
            cliKey = TerminalSettings.pgDumpCliPathKey
            binaryName = "pg_dump"
        case .restore:
            cliKey = TerminalSettings.pgRestoreCliPathKey
            binaryName = "pg_restore"
        }
        let customPath = AppSettingsManager.shared.terminal.cliPaths[cliKey]?.nilIfEmpty
        guard let resolvedPath = CLICommandResolver.findExecutable(binaryName, customPath: customPath) else {
            throw PostgresDumpError.binaryNotFound(name: binaryName)
        }

        let command = Self.buildCommand(
            kind: kind,
            executable: URL(fileURLWithPath: resolvedPath),
            effective: effective,
            database: database,
            fileURL: fileURL,
            password: password
        )

        try run(
            command: command,
            database: database,
            fileURL: fileURL,
            totalBytesEstimate: totalBytesEstimate
        )
        Self.logger.info("\(binaryName, privacy: .public) started db=\(database, privacy: .public)")
    }

    /// Test-friendly entry: spawns the given pre-built command via the runner
    /// and wires up termination/progress state. Skips dependency resolution.
    func run(
        command: PostgresDumpCommand,
        database: String,
        fileURL: URL,
        totalBytesEstimate: Int64? = nil
    ) throws {
        if case .running = state { throw PostgresDumpError.alreadyRunning }
        if case .cancelling = state { throw PostgresDumpError.alreadyRunning }

        let runner = runnerFactory()
        try runner.start(command)
        self.runner = runner

        state = .running(database: database, fileURL: fileURL, bytesProcessed: 0, totalBytes: totalBytesEstimate)
        if kind == .backup {
            startByteSizePolling(url: fileURL, database: database, totalBytes: totalBytesEstimate)
        }

        Task { @MainActor [weak self] in
            guard let result = await self?.runner?.result else { return }
            self?.handleTermination(result: result, database: database, fileURL: fileURL)
        }
    }

    func cancel() {
        guard case .running = state else { return }
        state = .cancelling
        runner?.cancel()
    }

    // MARK: - Command Construction

    static func buildCommand(
        kind: PostgresDumpKind,
        executable: URL,
        effective: DatabaseConnection,
        database: String,
        fileURL: URL,
        password: String?
    ) -> PostgresDumpCommand {
        var args: [String] = ["--no-password"]
        args.append(contentsOf: ["-h", effective.host.isEmpty ? "127.0.0.1" : effective.host])
        args.append(contentsOf: ["-p", String(effective.port)])
        if !effective.username.isEmpty {
            args.append(contentsOf: ["-U", effective.username])
        }
        switch kind {
        case .backup:
            args.append("-Fc")
            args.append(contentsOf: ["-d", database])
            args.append(contentsOf: ["-f", fileURL.path])
        case .restore:
            args.append("--no-owner")
            args.append("--no-acl")
            args.append(contentsOf: ["-d", database])
            args.append(fileURL.path)
        }

        var env = ProcessInfo.processInfo.environment
        if let password, !password.isEmpty {
            env["PGPASSWORD"] = password
        }
        if effective.sslConfig.isEnabled {
            env["PGSSLMODE"] = pgSSLMode(effective.sslConfig.mode)
        }
        return PostgresDumpCommand(
            executable: executable,
            arguments: args,
            environment: env,
            stderrByteCap: 64_000
        )
    }

    static func pgSSLMode(_ mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "disable"
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    // MARK: - Termination + Progress

    private func handleTermination(
        result: PostgresDumpRunResult,
        database: String,
        fileURL: URL
    ) {
        byteSizeTask?.cancel()
        byteSizeTask = nil
        runner = nil

        let writtenBytes: Int64
        if kind == .backup {
            writtenBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        } else {
            writtenBytes = 0
        }

        if result.wasCancelled {
            if kind == .backup {
                try? FileManager.default.removeItem(at: fileURL)
            }
            state = .cancelled
            Self.logger.notice("\(self.kind == .backup ? "pg_dump" : "pg_restore", privacy: .public) cancelled db=\(database, privacy: .public)")
            return
        }

        if result.exitCode == 0 {
            state = .finished(database: database, fileURL: fileURL, bytesProcessed: writtenBytes)
            Self.logger.info("\(self.kind == .backup ? "pg_dump" : "pg_restore", privacy: .public) finished bytes=\(writtenBytes) db=\(database, privacy: .public)")
            return
        }

        if kind == .backup {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let summary = result.stderr.isEmpty
            ? String(format: String(localized: "Process exited with code %d"), Int(result.exitCode))
            : result.stderr
        state = .failed(message: summary)
        Self.logger.error("\(self.kind == .backup ? "pg_dump" : "pg_restore", privacy: .public) failed code=\(result.exitCode) db=\(database, privacy: .public) stderr=\(result.stderr, privacy: .public)")
    }

    private func startByteSizePolling(url: URL, database: String, totalBytes: Int64?) {
        byteSizeTask?.cancel()
        byteSizeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                guard case .running = self.state else { return }
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                self.state = .running(
                    database: database,
                    fileURL: url,
                    bytesProcessed: size,
                    totalBytes: totalBytes
                )
            }
        }
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Real Process Runner

/// Concrete `PostgresDumpRunner` that spawns a real subprocess.
/// stderr is accumulated entirely off the main actor inside the
/// `readabilityHandler` closure and the termination handler;
/// only the final string crosses back to MainActor through `result`.
final class ProcessPostgresDumpRunner: PostgresDumpRunner {
    private let process = Process()
    private let stderrPipe = Pipe()
    private let bufferLock = NSLock()
    private var stderrBuffer = Data()
    private var stderrCap = 64_000
    private var wasCancelled = false
    private var continuation: CheckedContinuation<PostgresDumpRunResult, Never>?

    func start(_ command: PostgresDumpCommand) throws {
        stderrCap = command.stderrByteCap

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.bufferLock.lock()
            self.stderrBuffer.append(chunk)
            if self.stderrBuffer.count > self.stderrCap {
                self.stderrBuffer = Data(self.stderrBuffer.suffix(self.stderrCap))
            }
            self.bufferLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil

            self.bufferLock.lock()
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.bufferLock.unlock()

            let result = PostgresDumpRunResult(
                exitCode: proc.terminationStatus,
                stderr: stderrText,
                wasCancelled: self.wasCancelled
            )
            self.continuation?.resume(returning: result)
            self.continuation = nil
        }

        try process.run()
    }

    func cancel() {
        wasCancelled = true
        if process.isRunning {
            process.terminate()
        }
    }

    var result: PostgresDumpRunResult {
        get async {
            await withCheckedContinuation { continuation in
                if !process.isRunning {
                    self.bufferLock.lock()
                    let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.bufferLock.unlock()
                    continuation.resume(returning: PostgresDumpRunResult(
                        exitCode: process.terminationStatus,
                        stderr: stderrText,
                        wasCancelled: wasCancelled
                    ))
                } else {
                    self.continuation = continuation
                }
            }
        }
    }
}

// MARK: - Database Size Helper

extension PostgresDumpService {
    /// Best-effort estimate of the database's on-disk size. Used as an upper
    /// bound for the backup progress bar; the dump file is typically much
    /// smaller because of compression, so the bar tops out at the size and
    /// then jumps when pg_dump exits.
    /// Returns nil if the query fails or the driver isn't connected.
    static func estimatedDatabaseSize(
        connection: DatabaseConnection,
        database: String
    ) async -> Int64? {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return nil }
        let escaped = database.replacingOccurrences(of: "'", with: "''")
        let query = "SELECT pg_database_size('\(escaped)')"
        do {
            let result = try await driver.execute(query: query)
            guard let text = result.rows.first?.first?.asText else { return nil }
            return Int64(text)
        } catch {
            return nil
        }
    }
}
