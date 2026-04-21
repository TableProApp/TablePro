//
//  TerminalSessionState.swift
//  TablePro
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
    var isDisconnected: Bool = false
    var exitCode: Int32 = 0
    var error: String?

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.id = UUID()
        self.connectionId = connectionId
        self.databaseType = databaseType
    }

    // MARK: - Connect

    func connect(connection: DatabaseConnection, password: String?, activeDatabase: String?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let spec = CLICommandResolver.resolve(
                connection: connection,
                password: password,
                activeDatabase: activeDatabase
            )
            await MainActor.run { [weak self] in
                self?.launchProcess(spec: spec, connection: connection)
            }
        }
    }

    // MARK: - Reconnect

    func reconnect(connection: DatabaseConnection, password: String?, activeDatabase: String?) {
        disconnect()
        isDisconnected = false
        exitCode = 0
        error = nil
        terminalViewState = TerminalViewState()
        connect(connection: connection, password: password, activeDatabase: activeDatabase)
    }

    // MARK: - Disconnect

    func disconnect() {
        processManager?.terminate()
        processManager = nil
        session = nil
        isConnected = false
    }

    // MARK: - Private

    private func launchProcess(spec: CLILaunchSpec?, connection: DatabaseConnection) {
        guard let spec else {
            let binaryName = CLICommandResolver.binaryName(for: connection.type)
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
                manager?.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
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
                self.isDisconnected = true
                self.exitCode = status
                Self.logger.info("Terminal process exited with status \(status)")
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
}
