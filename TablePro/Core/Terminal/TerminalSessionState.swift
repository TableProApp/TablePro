//
//  TerminalSessionState.swift
//  TablePro
//
//  Observable state per terminal session, bridging PTY I/O
//  to the libghostty terminal renderer.
//

import Foundation
import GhosttyTerminal
import os

@MainActor @Observable
final class TerminalSessionState: Identifiable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TerminalSessionState")

    let id: UUID
    let connectionId: UUID
    let databaseType: DatabaseType

    var terminalViewState = TerminalViewState()
    var session: InMemoryTerminalSession?
    var processManager: TerminalProcessManager?
    var isConnected: Bool = false
    var error: String?

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.id = UUID()
        self.connectionId = connectionId
        self.databaseType = databaseType
    }

    // MARK: - Connect

    func connect(connection: DatabaseConnection, password: String?, activeDatabase: String?) {
        let spec = CLICommandResolver.resolve(
            connection: connection,
            password: password,
            activeDatabase: activeDatabase
        )

        guard let spec else {
            let binaryName = cliBinaryName(for: connection.type)
            error = String(
                format: String(localized: "CLI tool \"%@\" not found in PATH"),
                binaryName
            )
            Self.logger.warning("CLI not found for \(connection.type.rawValue, privacy: .public)")
            return
        }

        let manager = TerminalProcessManager()
        self.processManager = manager

        let inMemorySession = InMemoryTerminalSession(
            write: { [weak manager] data in
                manager?.write(data)
            },
            resize: { [weak manager] viewport in
                manager?.resize(cols: viewport.columns, rows: viewport.rows)
            }
        )
        self.session = inMemorySession

        manager.onData = { [weak inMemorySession] data in
            inMemorySession?.receive(data)
        }

        manager.onExit = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = false
                if status != 0 {
                    Self.logger.info("Terminal process exited with status \(status)")
                }
            }
        }

        do {
            try manager.launch(spec: spec)
            isConnected = true
            Self.logger.info("Terminal connected for \(connection.type.rawValue, privacy: .public)")
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("Failed to launch terminal: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        processManager?.terminate()
        processManager = nil
        session = nil
        isConnected = false
    }

    // MARK: - Private

    private func cliBinaryName(for type: DatabaseType) -> String {
        switch type {
        case .mysql, .mariadb: return "mysql"
        case .postgresql, .redshift: return "psql"
        case .redis: return "redis-cli"
        case .mongodb: return "mongosh"
        case .sqlite: return "sqlite3"
        case .mssql: return "sqlcmd"
        case .clickhouse: return "clickhouse-client"
        case .duckdb: return "duckdb"
        default: return type.rawValue.lowercased()
        }
    }
}
