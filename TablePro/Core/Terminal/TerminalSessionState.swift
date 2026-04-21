//
//  TerminalSessionState.swift
//  TablePro
//

import Foundation
import GhosttyTerminal
import GhosttyTheme
import os

@MainActor @Observable
final class TerminalSessionState: Identifiable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TerminalSessionState")

    let id: UUID
    let connectionId: UUID
    let databaseType: DatabaseType

    var terminalViewState: TerminalViewState
    var session: InMemoryTerminalSession?
    var processManager: TerminalProcessManager?
    var isConnected: Bool = false
    var isDisconnected: Bool = false
    var exitCode: Int32 = 0
    var error: String?

    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.id = UUID()
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.terminalViewState = Self.buildTerminalViewState()

        observeSettingsChanges()
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Connect

    func connect(connection: DatabaseConnection, password: String?, activeDatabase: String?) {
        let customCliPath = CLICommandResolver.userConfiguredPath(for: databaseType)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let dbType = await self.databaseType
            let spec = CLICommandResolver.resolve(
                connection: connection,
                password: password,
                activeDatabase: activeDatabase,
                databaseType: dbType,
                customCliPath: customCliPath
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
        terminalViewState = Self.buildTerminalViewState()
        connect(connection: connection, password: password, activeDatabase: activeDatabase)
    }

    // MARK: - Disconnect

    func disconnect() {
        processManager?.terminate()
        processManager = nil
        session = nil
        isConnected = false
    }

    // MARK: - Configuration

    private static func buildTerminalViewState() -> TerminalViewState {
        let settings = AppSettingsManager.shared.terminal
        let config = buildTerminalConfiguration(from: settings)
        let theme = buildTerminalTheme(from: settings)
        return TerminalViewState(
            configSource: .none,
            theme: theme,
            terminalConfiguration: config
        )
    }

    private static func buildTerminalConfiguration(from settings: TerminalSettings) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily(settings.fontFamily)
            builder.withFontSize(Float(settings.fontSize))

            let cursorStyle: GhosttyTerminal.TerminalCursorStyle = switch settings.cursorStyle {
            case .block: .block
            case .bar: .bar
            case .underline: .underline
            }
            builder.withCursorStyle(cursorStyle)
            builder.withCursorStyleBlink(settings.cursorBlink)

            if settings.scrollbackLines > 0 {
                builder.withCustom("scrollback-limit", String(settings.scrollbackLines))
            } else {
                builder.withCustom("scrollback-limit", "unlimited")
            }

            if settings.optionAsMeta {
                builder.withCustom("macos-option-as-alt", "true")
            }

            builder.withWindowPaddingX(4)
            builder.withWindowPaddingY(4)
        }
    }

    private static func buildTerminalTheme(from settings: TerminalSettings) -> TerminalTheme {
        guard !settings.themeName.isEmpty,
              let themeDef = GhosttyThemeCatalog.theme(named: settings.themeName)
        else {
            return .default
        }
        return themeDef.toTerminalTheme()
    }

    private func applySettingsToTerminal() {
        let settings = AppSettingsManager.shared.terminal
        let config = Self.buildTerminalConfiguration(from: settings)
        let theme = Self.buildTerminalTheme(from: settings)
        terminalViewState.setTheme(theme)
        terminalViewState.setTerminalConfiguration(config)
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettingsToTerminal()
            }
        }
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
                let bytes = [UInt8](data)
                let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let ascii = bytes.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
                Logger(subsystem: "com.TablePro", category: "TerminalIO")
                    .debug("WRITE \(bytes.count) bytes: [\(hex, privacy: .public)] ascii=[\(ascii, privacy: .public)]")
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
