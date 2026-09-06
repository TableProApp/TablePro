//
//  NativeDumpService.swift
//  TablePro
//
//  Consolidated backup + restore state machine. The work itself is delegated to a
//  `NativeDumpRunner` so the state machine can be exercised in tests with a fake one,
//  and so an engine that dumps through its own statements can share every bit of the
//  progress, cancel and result handling that spawning a process already had.
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
    /// A restore that fails part way through has already replayed some of the dump, and the
    /// target is left in whatever state that reached. A backup writes only to its own file, which
    /// is removed, so nothing of the user's is touched.
    case failed(message: String, targetMayBeModified: Bool)
    case cancelled
}

enum NativeDumpError: LocalizedError, Equatable {
    case binaryNotFound(name: String, installHint: String)
    case unsupportedDatabase
    case noSession
    case alreadyRunning
    case sourceUnreadable
    case engineStatementUnavailable

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name, let installHint):
            return String(
                format: String(localized: "%1$@ was not found on this system. %2$@"),
                name,
                installHint
            )
        case .unsupportedDatabase:
            return String(localized: "This database type has no dump TablePro can drive.")
        case .noSession:
            return String(localized: "Connect to the database before starting this operation.")
        case .alreadyRunning:
            return String(localized: "An operation is already running.")
        case .sourceUnreadable:
            return String(localized: "The selected backup file is not readable.")
        case .engineStatementUnavailable:
            return String(localized: "TablePro could not read the database's own name from the connection.")
        }
    }
}

/// Parameters for a single backup or restore subprocess.
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

/// Parameters for a dump the engine runs for itself.
struct NativeDumpStatementJob: Sendable, Equatable {
    let statements: [String]
    /// Run after a failure and ignored. A `DETACH` inside a transaction the engine already aborted
    /// fails too, and the caller has the real error to report instead of this one.
    let cleanupStatements: [String]
    let scope: DatabaseScope
}

/// What a run is, so the service can pick a runner without either runner accepting a shape it
/// cannot execute.
enum NativeDumpJob {
    case process(NativeDumpCommand)
    case statements(NativeDumpStatementJob)
}

/// Captured terminal state of a finished/cancelled run.
struct NativeDumpRunResult: Equatable {
    let exitCode: Int32
    let stderr: String
    let wasCancelled: Bool
}

/// Runs one backup or restore and reports how it ended. Abstracted so the state machine can be
/// tested without launching a process or reaching a database.
protocol NativeDumpRunner: AnyObject {
    /// Begins the work. Throws synchronously if it cannot be started at all.
    func start() throws
    /// Asks for cancellation. Safe to call more than once.
    func cancel()
    /// Resolves once the work has ended, however it ended.
    var result: NativeDumpRunResult { get async }
}

// MARK: - Service

@MainActor
@Observable
final class NativeDumpService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "NativeDumpService")

    let kind: NativeDumpKind
    private(set) var state: NativeDumpState = .idle

    @ObservationIgnored private let runnerFactory: @MainActor (NativeDumpJob) -> any NativeDumpRunner
    @ObservationIgnored private var runner: (any NativeDumpRunner)?
    @ObservationIgnored private var byteSizeTask: Task<Void, Never>?
    @ObservationIgnored private var stateObservers: [UUID: AsyncStream<NativeDumpState>.Continuation] = [:]
    @ObservationIgnored private var toolName = "dump"

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

    /// Default initializer picks the runner the job calls for.
    init(kind: NativeDumpKind) {
        self.kind = kind
        self.runnerFactory = { job in
            switch job {
            case .process(let command):
                return ProcessNativeDumpRunner(command: command)
            case .statements(let job):
                return InProcessDumpRunner(job: job)
            }
        }
    }

    /// Test-friendly initializer that injects a custom runner factory.
    init(kind: NativeDumpKind, runnerFactory: @escaping @MainActor (NativeDumpJob) -> any NativeDumpRunner) {
        self.kind = kind
        self.runnerFactory = runnerFactory
    }

    /// Starts the operation. `fileURL` is the destination for `.backup` and the source for
    /// `.restore`. `totalBytesEstimate` enables a determinate progress bar.
    ///
    /// This entry point resolves dependencies from app singletons (`DatabaseManager`,
    /// `ConnectionStorage`, `CLIExecutableFinder`, `PluginManager`). Tests should use
    /// `run(job:database:fileURL:totalBytesEstimate:)` directly with a fake runner.
    func start(
        connection: DatabaseConnection,
        database: String,
        fileURL: URL,
        scope: NativeDumpScope = .wholeDatabase,
        formatId: String? = nil,
        totalBytesEstimate: Int64? = nil
    ) async throws {
        if case .running = state { throw NativeDumpError.alreadyRunning }
        if case .cancelling = state { throw NativeDumpError.alreadyRunning }

        guard let descriptor = NativeDumpRegistry.descriptor(for: connection.type, formatId: formatId) else {
            throw NativeDumpError.unsupportedDatabase
        }

        let session = DatabaseManager.shared.session(for: connection.id)
        guard session?.isConnected == true else { throw NativeDumpError.noSession }

        if kind == .restore, !descriptor.archiveFormat.producesDirectory {
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw NativeDumpError.sourceUnreadable
            }
        }

        let effective = session?.effectiveConnection ?? connection
        let password = ConnectionStorage.shared.loadPassword(for: connection.id) ?? session?.cachedPassword
        let localFilePath = Self.localFilePath(for: effective)
        let catalog = descriptor.engineStatements == nil
            ? nil
            : await Self.resolvedCatalog(connectionId: connection.id, database: database)

        let request = NativeDumpDescriptor.Request(
            connection: effective,
            database: database,
            fileURL: fileURL,
            password: password,
            scope: scope,
            currentCatalog: catalog,
            localFilePath: localFilePath
        )

        switch descriptor.mechanism {
        case .commandLineTool(let tool):
            let candidates = tool.binaries(for: kind)
            guard let resolved = candidates.lazy.compactMap({ name -> (String, String)? in
                guard let path = CLIExecutableFinder.findExecutable(name) else { return nil }
                return (name, path)
            }).first else {
                throw NativeDumpError.binaryNotFound(
                    name: candidates.formatted(.list(type: .or)),
                    installHint: tool.installHint
                )
            }
            let (binaryName, resolvedPath) = resolved
            toolName = binaryName
            let command = try Self.buildCommand(
                kind: kind,
                tool: tool,
                executable: URL(fileURLWithPath: resolvedPath),
                request: request
            )
            try run(job: .process(command), database: database, fileURL: fileURL, totalBytesEstimate: totalBytesEstimate)

        case .engineStatements(let engine):
            let alias = Self.backupAlias()
            let statements = engine.statements(for: kind, request: request, alias: alias)
            guard !statements.isEmpty else { throw NativeDumpError.engineStatementUnavailable }
            toolName = connection.type.rawValue
            let scopeForRun = DatabaseManager.shared.resolvedScope(
                database: database, schema: nil, for: connection.id
            ) ?? DatabaseScope(connectionId: connection.id, database: database, schema: nil)
            try run(
                job: .statements(
                    NativeDumpStatementJob(
                        statements: statements,
                        cleanupStatements: engine.cleanupStatements(alias),
                        scope: scopeForRun
                    )
                ),
                database: database,
                fileURL: fileURL,
                totalBytesEstimate: totalBytesEstimate
            )
        }

        Self.logger.info("\(self.toolName, privacy: .public) started db=\(database, privacy: .public)")
    }

    /// Test-friendly entry: hands the job to the runner and wires up termination and progress.
    /// Skips dependency resolution.
    func run(
        job: NativeDumpJob,
        database: String,
        fileURL: URL,
        totalBytesEstimate: Int64? = nil
    ) throws {
        if case .running = state { throw NativeDumpError.alreadyRunning }
        if case .cancelling = state { throw NativeDumpError.alreadyRunning }

        let runner = runnerFactory(job)
        try runner.start()
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

    // MARK: - Resolution

    /// The path a file-backed driver actually opens, read from wherever that driver keeps it.
    /// SQLite uses `database`; DuckDB and libSQL use a plugin-declared additional field.
    static func localFilePath(for connection: DatabaseConnection) -> String? {
        guard let field = PluginManager.shared.localFilePathField(for: connection.type) else { return nil }
        let path = connection.localFilePath(in: field)
        return path.isEmpty ? nil : path
    }

    /// The engine's own name for the database being dumped.
    ///
    /// `COPY FROM DATABASE` names a catalog, and DuckDB derives a catalog name from the file's
    /// basename: measured, `my-weird.name.db` attaches as `my-weird`, and `COPY FROM DATABASE main`
    /// fails with `Catalog "main" does not exist`. DuckDB also reaches more than one catalog at once
    /// through `ATTACH`, so the answer is the picked database when the engine lists it, and only
    /// otherwise the one the session is on.
    static func resolvedCatalog(connectionId: UUID, database: String) async -> String? {
        guard let scope = DatabaseManager.shared.resolvedScope(
            database: database, schema: nil, for: connectionId
        ) else { return nil }
        return try? await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            let reported = (try? await driver.fetchDatabases()) ?? []
            let current = try? await driver.execute(query: "SELECT current_database()")
            return catalogName(
                picked: database,
                reported: reported,
                current: current?.rows.first?.first?.asText
            )
        }
    }

    /// Pure so the choice is testable without an engine. The picked name wins when the engine says
    /// it exists, because a connection with two catalogs attached has to dump the one that was
    /// ticked rather than whichever the session is parked on.
    nonisolated static func catalogName(
        picked: String,
        reported: [String],
        current: String?
    ) -> String? {
        if !picked.isEmpty, reported.contains(picked) { return picked }
        if let current, !current.isEmpty { return current }
        return picked.isEmpty ? nil : picked
    }

    /// Unique per run, so a `DETACH` that could not execute leaves nothing behind that blocks the
    /// next attempt with "database with name already exists".
    static func backupAlias() -> String {
        "tablepro_backup_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    }

    // MARK: - Command Construction

    /// The descriptor supplies the arguments and the environment; this adds the parts every tool
    /// shares. A password never joins the argument list, because `argv` is world readable through
    /// `ps`: it goes in the environment where the tool reads one, and in a `0600` file where it
    /// does not.
    nonisolated static func buildCommand(
        kind: NativeDumpKind,
        tool: NativeDumpDescriptor.CommandLineTool,
        executable: URL,
        request: NativeDumpDescriptor.Request
    ) throws -> NativeDumpCommand {
        var arguments = tool.arguments(for: kind, request: request)
        var environment = minimalEnvironment()
        environment.merge(tool.environment(request)) { _, new in new }

        var credentialsFileURL: URL?
        if tool.needsCredentialsFile,
           let password = request.password, !password.isEmpty,
           !request.connection.username.isEmpty {
            let file = try writeMongoCredentialsFile(password: password)
            credentialsFileURL = file
            arguments.append("--config=\(file.path)")
        }

        let delivery = tool.delivery(for: kind)
        return NativeDumpCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            stderrByteCap: 64_000,
            delivery: delivery,
            redirectedFileURL: delivery == .standardOutput ? request.fileURL : nil,
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

    // MARK: - Termination + Progress

    private func handleTermination(
        result: NativeDumpRunResult,
        database: String,
        fileURL: URL
    ) {
        byteSizeTask?.cancel()
        byteSizeTask = nil
        runner = nil

        let writtenBytes: Int64 = kind == .backup ? Self.sizeOfDestination(fileURL) : 0

        if result.wasCancelled {
            if kind == .backup { Self.removeDestination(fileURL) }
            setState(.cancelled)
            Self.logger.notice("\(self.toolName, privacy: .public) cancelled db=\(database, privacy: .public)")
            return
        }

        if result.exitCode == 0 {
            setState(.finished(database: database, fileURL: fileURL, bytesProcessed: writtenBytes))
            Self.logger.info("\(self.toolName, privacy: .public) finished bytes=\(writtenBytes) db=\(database, privacy: .public)")
            return
        }

        if kind == .backup { Self.removeDestination(fileURL) }
        let summary = result.stderr.isEmpty
            ? String(format: String(localized: "Process exited with code %d"), Int(result.exitCode))
            : result.stderr
        setState(.failed(message: summary, targetMayBeModified: kind == .restore))
        Self.logger.error("\(self.toolName, privacy: .public) failed code=\(result.exitCode) db=\(database, privacy: .public) stderr=\(result.stderr)")
    }

    /// A DuckDB Parquet backup is a folder, so its size is the sum of what is inside it and its
    /// removal is recursive. `removeItem` already handles a directory; `attributesOfItem` does not
    /// sum one.
    nonisolated static func sizeOfDestination(_ url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let size = (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    nonisolated static func removeDestination(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startByteSizePolling(url: URL, database: String, totalBytes: Int64?) {
        byteSizeTask?.cancel()
        byteSizeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                guard case .running = self.state else { return }
                self.setState(.running(
                    database: database,
                    fileURL: url,
                    bytesProcessed: Self.sizeOfDestination(url),
                    totalBytes: totalBytes
                ))
            }
        }
    }
}

// MARK: - Database Size Helper

extension NativeDumpService {
    /// Best-effort estimate of the database's on-disk size. Used as an upper bound for the backup
    /// progress bar; the dump file is typically much smaller because of compression, so the bar
    /// tops out at the size and then jumps when the tool exits. Returns nil if the query fails.
    ///
    /// Routed through `withMetadataDriver` rather than taken straight off `driver(for:)`. On the
    /// session driver this query queues behind whatever the user is running and joins whatever
    /// transaction a query tab left open, which is the hazard `metadataRoute` exists to avoid.
    static func estimatedDatabaseSize(
        connection: DatabaseConnection,
        database: String
    ) async -> Int64? {
        guard let query = sizeQuery(for: connection.type) else { return nil }
        guard let scope = DatabaseManager.shared.resolvedScope(
            database: database, schema: nil, for: connection.id
        ) else { return nil }
        let result = try? await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.executeParameterized(query: query, parameters: [database])
        }
        guard let text = result?.rows.first?.first?.asText else { return nil }
        return Int64(text)
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
