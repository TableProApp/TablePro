//
//  PostgresBackupService.swift
//  TablePro
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class PostgresBackupService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PostgresBackupService")

    enum State: Equatable {
        case idle
        case running(database: String, bytesWritten: Int64)
        case cancelling
        case finished(database: String, destination: URL, bytesWritten: Int64)
        case failed(message: String)
        case cancelled
    }

    enum BackupError: LocalizedError {
        case pgDumpNotFound
        case unsupportedDatabase
        case noSession
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .pgDumpNotFound:
                return String(localized: """
                    pg_dump was not found on this system. Install it with `brew install libpq` and \
                    link it, or set a custom path under Settings > Terminal > CLI Paths > pg_dump.
                    """)
            case .unsupportedDatabase:
                return String(localized: "Backups are only supported for PostgreSQL and Redshift connections.")
            case .noSession:
                return String(localized: "Connect to the database before starting a backup.")
            case .alreadyRunning:
                return String(localized: "A backup is already running.")
            }
        }
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stderrBuffer = Data()
    @ObservationIgnored private var byteSizeTask: Task<Void, Never>?

    /// Returns the resolved pg_dump executable path, honoring the user-configured override.
    nonisolated static func resolvePgDumpPath(customPath: String?) -> String? {
        CLICommandResolver.findExecutable("pg_dump", customPath: customPath)
    }

    private static func pgSSLMode(_ mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "disable"
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    func start(connection: DatabaseConnection, database: String, destination: URL) async throws {
        if case .running = state { throw BackupError.alreadyRunning }
        if case .cancelling = state { throw BackupError.alreadyRunning }

        guard connection.type == .postgresql || connection.type == .redshift else {
            throw BackupError.unsupportedDatabase
        }

        let session = DatabaseManager.shared.session(for: connection.id)
        guard session?.isConnected == true else {
            throw BackupError.noSession
        }

        let effective = session?.effectiveConnection ?? connection

        let customPath = AppSettingsManager.shared.terminal.cliPaths[TerminalSettings.pgDumpCliPathKey]?.nilIfEmpty
        guard let pgDumpPath = Self.resolvePgDumpPath(customPath: customPath) else {
            throw BackupError.pgDumpNotFound
        }

        let password = ConnectionStorage.shared.loadPassword(for: connection.id) ?? session?.cachedPassword

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pgDumpPath)

        var args: [String] = [
            "-Fc",
            "--no-password",
            "-h", effective.host.isEmpty ? "127.0.0.1" : effective.host,
            "-p", String(effective.port),
            "-d", database,
            "-f", destination.path
        ]
        if !effective.username.isEmpty {
            args.append(contentsOf: ["-U", effective.username])
        }
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        if let password, !password.isEmpty {
            env["PGPASSWORD"] = password
        }
        if effective.sslConfig.isEnabled {
            env["PGSSLMODE"] = Self.pgSSLMode(effective.sslConfig.mode)
        }
        proc.environment = env

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = FileHandle.nullDevice

        stderrBuffer = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.stderrBuffer.append(chunk)
                if self?.stderrBuffer.count ?? 0 > 64_000 {
                    let trimmed = self?.stderrBuffer.suffix(64_000) ?? Data()
                    self?.stderrBuffer = Data(trimmed)
                }
            }
        }

        let dbName = database
        proc.terminationHandler = { [weak self] terminated in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.handleTermination(terminated, database: dbName, destination: destination)
            }
        }

        do {
            try proc.run()
        } catch {
            throw BackupError.pgDumpNotFound
        }

        self.process = proc
        state = .running(database: database, bytesWritten: 0)
        startByteSizePolling(url: destination, database: database)

        Self.logger.info("pg_dump started pid=\(proc.processIdentifier, privacy: .public) db=\(dbName, privacy: .public)")
    }

    func cancel() {
        guard case .running = state, let proc = process else { return }
        state = .cancelling
        proc.terminate()
    }

    private func handleTermination(_ proc: Process, database: String, destination: URL) {
        byteSizeTask?.cancel()
        byteSizeTask = nil
        process = nil

        let exitCode = proc.terminationStatus
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        if exitCode == 0 {
            state = .finished(database: database, destination: destination, bytesWritten: bytes)
            Self.logger.info("pg_dump finished bytes=\(bytes) db=\(database, privacy: .public)")
            return
        }

        if case .cancelling = state {
            try? FileManager.default.removeItem(at: destination)
            state = .cancelled
            Self.logger.notice("pg_dump cancelled db=\(database, privacy: .public)")
            return
        }

        try? FileManager.default.removeItem(at: destination)
        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = stderrText.isEmpty
            ? String(format: String(localized: "pg_dump exited with code %d"), Int(exitCode))
            : stderrText
        state = .failed(message: summary)
        Self.logger.error("pg_dump failed code=\(exitCode) db=\(database, privacy: .public) stderr=\(stderrText, privacy: .public)")
    }

    private func startByteSizePolling(url: URL, database: String) {
        byteSizeTask?.cancel()
        byteSizeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                guard case .running = self.state else { return }
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                self.state = .running(database: database, bytesWritten: size)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
