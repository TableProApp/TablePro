//
//  NativeDumpService.swift
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
enum NativeDumpKind: Equatable, Sendable {
    case backup
    case restore
}

/// Observable state of a backup or restore.
enum NativeDumpState: Equatable {
    case idle
    case running(database: String, fileURL: URL, bytesProcessed: Int64, totalBytes: Int64?)
    case cancelling
    case finished(database: String, fileURL: URL, bytesProcessed: Int64)
    case failed(message: String)
    case cancelled
}

enum NativeDumpError: LocalizedError, Equatable {
    case binaryNotFound(name: String, installHint: String)
    case unsupportedDatabase
    case noSession
    case alreadyRunning
    case sourceUnreadable

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name, let installHint):
            return String(
                format: String(localized: "%1$@ was not found on this system. %2$@"),
                name,
                installHint
            )
        case .unsupportedDatabase:
            return String(localized: "This database type has no command line dump tool TablePro can drive.")
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
struct NativeDumpCommand: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let stderrByteCap: Int

    /// Where the tool's output goes. `pg_dump -Fc` is told a path and writes it itself, while
    /// `mysqldump` and `sqlite3 .dump` write SQL to standard output for the caller to redirect.
    let delivery: NativeDumpDescriptor.OutputDelivery

    /// The file standard output is redirected to, or read from on a restore. Nil when the tool
    /// handles the file itself.
    let redirectedFileURL: URL?

    /// A credentials file written for tools that read a password from neither the environment nor
    /// standard input. Removed once the process exits, however it exits.
    let temporaryCredentialsFileURL: URL?

    /// Which direction a redirected file goes: a restore feeds it in as standard input, a backup
    /// takes standard output and writes it out.
    let isRestore: Bool

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stderrByteCap: Int,
        delivery: NativeDumpDescriptor.OutputDelivery = .toolWritesFile,
        redirectedFileURL: URL? = nil,
        temporaryCredentialsFileURL: URL? = nil,
        isRestore: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stderrByteCap = stderrByteCap
        self.delivery = delivery
        self.redirectedFileURL = redirectedFileURL
        self.temporaryCredentialsFileURL = temporaryCredentialsFileURL
        self.isRestore = isRestore
    }
}

/// Captured terminal state of a finished/cancelled subprocess.
struct NativeDumpRunResult: Equatable {
    let exitCode: Int32
    let stderr: String
    let wasCancelled: Bool
}

/// Spawns and supervises a single subprocess. Abstracted so the dump
/// state machine can be tested without launching real processes.
protocol NativeDumpRunner: AnyObject {
    /// Launches the command. Throws synchronously if the binary can't be spawned.
    /// `result` returns the final outcome when the process exits.
    func start(_ command: NativeDumpCommand) throws
    /// Sends SIGTERM. Safe to call multiple times.
    func cancel()
    /// Resolves once the process has terminated (normally or via cancel).
    var result: NativeDumpRunResult { get async }
}

// MARK: - Service

@MainActor
@Observable
final class NativeDumpService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "NativeDumpService")

    let kind: NativeDumpKind
    private(set) var state: NativeDumpState = .idle

    @ObservationIgnored private let runnerFactory: () -> any NativeDumpRunner
    @ObservationIgnored private var runner: (any NativeDumpRunner)?
    @ObservationIgnored private var byteSizeTask: Task<Void, Never>?
    @ObservationIgnored private var stateObservers: [UUID: AsyncStream<NativeDumpState>.Continuation] = [:]

    func stateUpdates() -> AsyncStream<NativeDumpState> {
        let (stream, continuation) = AsyncStream<NativeDumpState>.makeStream()
        let id = UUID()
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.stateObservers.removeValue(forKey: id)
            }
        }
        return stream
    }

    private func setState(_ newState: NativeDumpState) {
        state = newState
        for continuation in stateObservers.values {
            continuation.yield(newState)
        }
    }

    /// Default initializer uses the real `Process`-backed runner.
    init(kind: NativeDumpKind) {
        self.kind = kind
        self.runnerFactory = { ProcessNativeDumpRunner() }
    }

    /// Test-friendly initializer that injects a custom runner factory.
    init(kind: NativeDumpKind, runnerFactory: @escaping () -> any NativeDumpRunner) {
        self.kind = kind
        self.runnerFactory = runnerFactory
    }

    /// Starts the operation. `fileURL` is the destination for `.backup` and
    /// the source for `.restore`. `totalBytesEstimate` enables a determinate
    /// progress bar (used by backup; restore stays indeterminate).
    ///
    /// This entry point resolves dependencies from app singletons
    /// (`DatabaseManager`, `ConnectionStorage`, `CLIExecutableFinder`).
    /// Tests should use `run(command:database:fileURL:totalBytesEstimate:)`
    /// directly with a fake runner.
    func start(
        connection: DatabaseConnection,
        database: String,
        fileURL: URL,
        totalBytesEstimate: Int64? = nil
    ) async throws {
        if case .running = state { throw NativeDumpError.alreadyRunning }
        if case .cancelling = state { throw NativeDumpError.alreadyRunning }

        guard let descriptor = NativeDumpRegistry.descriptor(for: connection.type) else {
            throw NativeDumpError.unsupportedDatabase
        }

        let session = DatabaseManager.shared.session(for: connection.id)
        guard session?.isConnected == true else { throw NativeDumpError.noSession }

        if kind == .restore {
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw NativeDumpError.sourceUnreadable
            }
        }

        let effective = session?.effectiveConnection ?? connection
        let password = ConnectionStorage.shared.loadPassword(for: connection.id) ?? session?.cachedPassword

        let candidates = descriptor.binaries(for: kind)
        guard let resolved = candidates.lazy.compactMap({ name -> (String, String)? in
            guard let path = CLIExecutableFinder.findExecutable(name) else { return nil }
            return (name, path)
        }).first else {
            throw NativeDumpError.binaryNotFound(
                name: candidates.joined(separator: String(localized: " or ")),
                installHint: descriptor.installHint
            )
        }
        let (binaryName, resolvedPath) = resolved

        let command = try Self.buildCommand(
            kind: kind,
            descriptor: descriptor,
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
        command: NativeDumpCommand,
        database: String,
        fileURL: URL,
        totalBytesEstimate: Int64? = nil
    ) throws {
        if case .running = state { throw NativeDumpError.alreadyRunning }
        if case .cancelling = state { throw NativeDumpError.alreadyRunning }

        let runner = runnerFactory()
        try runner.start(command)
        self.runner = runner

        setState(.running(database: database, fileURL: fileURL, bytesProcessed: 0, totalBytes: totalBytesEstimate))
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
        setState(.cancelling)
        runner?.cancel()
    }

    // MARK: - Command Construction

    /// The descriptor supplies the arguments and the environment; this adds the parts every tool
    /// shares. A password never joins the argument list, because `argv` is world readable through
    /// `ps`: it goes in the environment where the tool reads one, and in a `0600` file where it
    /// does not.
    nonisolated static func buildCommand(
        kind: NativeDumpKind,
        descriptor: NativeDumpDescriptor,
        executable: URL,
        effective: DatabaseConnection,
        database: String,
        fileURL: URL,
        password: String?
    ) throws -> NativeDumpCommand {
        let request = NativeDumpDescriptor.Request(
            connection: effective,
            database: database,
            fileURL: fileURL,
            password: password
        )
        var arguments = descriptor.arguments(for: kind, request: request)
        var environment = minimalEnvironment()
        environment.merge(descriptor.environment(request)) { _, new in new }

        var credentialsFileURL: URL?
        if descriptor.environment(request).isEmpty,
           let password, !password.isEmpty,
           !effective.username.isEmpty,
           descriptor.backupBinaries.contains("mongodump") {
            let file = try writeMongoCredentialsFile(password: password)
            credentialsFileURL = file
            arguments.append("--config=\(file.path)")
        }

        let delivery = descriptor.delivery(for: kind)
        return NativeDumpCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            stderrByteCap: 64_000,
            delivery: delivery,
            redirectedFileURL: delivery == .standardOutput ? fileURL : nil,
            temporaryCredentialsFileURL: credentialsFileURL,
            isRestore: kind == .restore
        )
    }

    /// `mongodump` and `mongorestore` read a password from neither the environment nor standard
    /// input, and one in `argv` is readable by every process on the machine. Their `--config` file
    /// is the remaining channel, so it is written owner-only and removed when the process exits.
    nonisolated static func writeMongoCredentialsFile(password: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-mongo-\(UUID().uuidString).yaml")
        let contents = "password: \(mongoYAMLQuoted(password))\n"
        guard let data = contents.data(using: .utf8) else {
            throw NativeDumpError.sourceUnreadable
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// A double-quoted YAML scalar, which is the one form that carries every character a password
    /// can hold without the value changing meaning.
    nonisolated static func mongoYAMLQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private static let inheritedEnvironmentKeys: [String] = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL"
    ]

    nonisolated static func minimalEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in inheritedEnvironmentKeys where parent[key] != nil {
            env[key] = parent[key]
        }
        return env
    }

    nonisolated static func pgSSLMode(_ mode: SSLMode) -> String? {
        switch mode {
        case .disabled: return nil
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    // MARK: - Termination + Progress

    private func handleTermination(
        result: NativeDumpRunResult,
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
            setState(.cancelled)
            Self.logger.notice("\(self.kind == .backup ? "pg_dump" : "pg_restore", privacy: .public) cancelled db=\(database, privacy: .public)")
            return
        }

        if result.exitCode == 0 {
            setState(.finished(database: database, fileURL: fileURL, bytesProcessed: writtenBytes))
            Self.logger.info("\(self.kind == .backup ? "pg_dump" : "pg_restore", privacy: .public) finished bytes=\(writtenBytes) db=\(database, privacy: .public)")
            return
        }

        if kind == .backup {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let summary = result.stderr.isEmpty
            ? String(format: String(localized: "Process exited with code %d"), Int(result.exitCode))
            : result.stderr
        setState(.failed(message: summary))
        Self.logger.error("\(self.kind == .backup ? "pg_dump" : "pg_restore", privacy: .public) failed code=\(result.exitCode) db=\(database, privacy: .public) stderr=\(result.stderr)")
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
                self.setState(.running(
                    database: database,
                    fileURL: url,
                    bytesProcessed: size,
                    totalBytes: totalBytes
                ))
            }
        }
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Real Process Runner

final class ProcessNativeDumpRunner: NativeDumpRunner, @unchecked Sendable {
    private let process = Process()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()
    private var stderrBuffer = Data()
    private var wasCancelled = false
    private var terminationResult: NativeDumpRunResult?
    private var continuation: CheckedContinuation<NativeDumpRunResult, Never>?
    private var redirectedHandle: FileHandle?
    private var credentialsFileURL: URL?

    func start(_ command: NativeDumpCommand) throws {
        let stderrCap = command.stderrByteCap

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardError = stderrPipe
        credentialsFileURL = command.temporaryCredentialsFileURL

        try attachRedirection(for: command)

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.stateLock.lock()
            self.stderrBuffer.append(chunk)
            if self.stderrBuffer.count > stderrCap {
                self.stderrBuffer = Data(self.stderrBuffer.suffix(stderrCap))
            }
            self.stateLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.releaseRedirection()

            self.stateLock.lock()
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let result = NativeDumpRunResult(
                exitCode: proc.terminationStatus,
                stderr: stderrText,
                wasCancelled: self.wasCancelled
            )
            self.terminationResult = result
            let pending = self.continuation
            self.continuation = nil
            self.stateLock.unlock()

            pending?.resume(returning: result)
        }

        try process.run()
    }

    func cancel() {
        stateLock.lock()
        wasCancelled = true
        stateLock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    /// A tool that writes to standard output gets the destination file as its stdout, and a restore
    /// that reads from standard input gets the dump file as its stdin. The one that manages its own
    /// file gets the null device, which is what keeps a chatty tool from filling a pipe nobody
    /// drains and deadlocking on write.
    private func attachRedirection(for command: NativeDumpCommand) throws {
        guard command.delivery == .standardOutput, let fileURL = command.redirectedFileURL else {
            process.standardOutput = FileHandle.nullDevice
            return
        }
        switch command.isRestore {
        case true:
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw NativeDumpError.sourceUnreadable
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            redirectedHandle = handle
            process.standardInput = handle
            process.standardOutput = FileHandle.nullDevice
        case false:
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw NativeDumpError.sourceUnreadable
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            redirectedHandle = handle
            process.standardOutput = handle
        }
    }

    /// Runs however the process ended, including a cancel, so a credentials file never outlives the
    /// process that needed it.
    private func releaseRedirection() {
        try? redirectedHandle?.close()
        redirectedHandle = nil
        if let credentialsFileURL {
            try? FileManager.default.removeItem(at: credentialsFileURL)
        }
        credentialsFileURL = nil
    }

    var result: NativeDumpRunResult {
        get async {
            await withCheckedContinuation { continuation in
                stateLock.lock()
                if let cached = terminationResult {
                    stateLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                self.continuation = continuation
                stateLock.unlock()
            }
        }
    }
}

// MARK: - Database Size Helper

extension NativeDumpService {
    /// Best-effort estimate of the database's on-disk size. Used as an upper
    /// bound for the backup progress bar; the dump file is typically much
    /// smaller because of compression, so the bar tops out at the size and
    /// then jumps when pg_dump exits.
    /// Returns nil if the query fails or the driver isn't connected.
    static func estimatedDatabaseSize(
        connection: DatabaseConnection,
        database: String
    ) async -> Int64? {
        guard let query = sizeQuery(for: connection.type) else { return nil }
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return nil }
        do {
            let result = try await driver.executeParameterized(query: query, parameters: [database])
            guard let text = result.rows.first?.first?.asText else { return nil }
            return Int64(text)
        } catch {
            return nil
        }
    }

    /// An engine with no cheap size answer returns nil, which leaves the progress bar
    /// indeterminate rather than showing a percentage of a number nobody measured.
    nonisolated static func sizeQuery(for type: DatabaseType) -> String? {
        switch type {
        case .postgresql, .redshift:
            return "SELECT pg_database_size($1)"
        case .mysql, .mariadb:
            return """
                SELECT COALESCE(SUM(data_length + index_length), 0)
                FROM information_schema.TABLES WHERE table_schema = ?
                """
        default:
            return nil
        }
    }
}
