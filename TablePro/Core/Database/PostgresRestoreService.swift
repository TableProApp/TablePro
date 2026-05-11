//
//  PostgresRestoreService.swift
//  TablePro
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class PostgresRestoreService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PostgresRestoreService")

    enum State: Equatable {
        case idle
        case running(database: String, source: URL)
        case cancelling
        case finished(database: String, source: URL)
        case failed(message: String)
        case cancelled
    }

    enum RestoreError: LocalizedError {
        case pgRestoreNotFound
        case unsupportedDatabase
        case noSession
        case alreadyRunning
        case sourceUnreadable

        var errorDescription: String? {
            switch self {
            case .pgRestoreNotFound:
                return String(localized: """
                    pg_restore was not found on this system. Install it with `brew install libpq` and \
                    link it, or set a custom path under Settings > Terminal > CLI Paths > pg_restore.
                    """)
            case .unsupportedDatabase:
                return String(localized: "Restore is only supported for PostgreSQL and Redshift connections.")
            case .noSession:
                return String(localized: "Connect to the database before starting a restore.")
            case .alreadyRunning:
                return String(localized: "A restore is already running.")
            case .sourceUnreadable:
                return String(localized: "The selected backup file is not readable.")
            }
        }
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stderrBuffer = Data()

    /// Returns the resolved pg_restore executable path, honoring the user-configured override.
    nonisolated static func resolvePgRestorePath(customPath: String?) -> String? {
        CLICommandResolver.findExecutable("pg_restore", customPath: customPath)
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

    func start(connection: DatabaseConnection, database: String, source: URL) async throws {
        if case .running = state { throw RestoreError.alreadyRunning }
        if case .cancelling = state { throw RestoreError.alreadyRunning }

        guard connection.type == .postgresql || connection.type == .redshift else {
            throw RestoreError.unsupportedDatabase
        }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw RestoreError.sourceUnreadable
        }

        let session = DatabaseManager.shared.session(for: connection.id)
        guard session?.isConnected == true else {
            throw RestoreError.noSession
        }

        let effective = session?.effectiveConnection ?? connection

        let customPath = AppSettingsManager.shared.terminal
            .cliPaths[TerminalSettings.pgRestoreCliPathKey]?.nilIfEmpty
        guard let pgRestorePath = Self.resolvePgRestorePath(customPath: customPath) else {
            throw RestoreError.pgRestoreNotFound
        }

        let password = ConnectionStorage.shared.loadPassword(for: connection.id) ?? session?.cachedPassword

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pgRestorePath)

        var args: [String] = [
            "--no-password",
            "--no-owner",
            "--no-acl",
            "-h", effective.host.isEmpty ? "127.0.0.1" : effective.host,
            "-p", String(effective.port),
            "-d", database
        ]
        if !effective.username.isEmpty {
            args.append(contentsOf: ["-U", effective.username])
        }
        args.append(source.path)
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
        let sourceURL = source
        proc.terminationHandler = { [weak self] terminated in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.handleTermination(terminated, database: dbName, source: sourceURL)
            }
        }

        do {
            try proc.run()
        } catch {
            throw RestoreError.pgRestoreNotFound
        }

        self.process = proc
        state = .running(database: database, source: source)

        Self.logger.info("pg_restore started pid=\(proc.processIdentifier, privacy: .public) db=\(dbName, privacy: .public)")
    }

    func cancel() {
        guard case .running = state, let proc = process else { return }
        state = .cancelling
        proc.terminate()
    }

    private func handleTermination(_ proc: Process, database: String, source: URL) {
        process = nil

        let exitCode = proc.terminationStatus

        if case .cancelling = state {
            state = .cancelled
            Self.logger.notice("pg_restore cancelled db=\(database, privacy: .public)")
            return
        }

        if exitCode == 0 {
            state = .finished(database: database, source: source)
            Self.logger.info("pg_restore finished db=\(database, privacy: .public)")
            return
        }

        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = stderrText.isEmpty
            ? String(format: String(localized: "pg_restore exited with code %d"), Int(exitCode))
            : stderrText
        state = .failed(message: summary)
        Self.logger.error("pg_restore failed code=\(exitCode) db=\(database, privacy: .public) stderr=\(stderrText, privacy: .public)")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
