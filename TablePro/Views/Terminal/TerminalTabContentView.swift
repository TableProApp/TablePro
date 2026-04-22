//
//  TerminalTabContentView.swift
//  TablePro
//

import GhosttyTerminal
import SwiftUI

struct TerminalTabContentView: View {
    let tab: QueryTab
    let connection: DatabaseConnection
    let connectionId: UUID

    @State private var sessionState: TerminalSessionState?
    @State private var configuredSessionId: ObjectIdentifier?

    var body: some View {
        ZStack {
            if let state = sessionState {
                if let error = state.error {
                    TerminalErrorView(error: error, databaseType: connection.type)
                } else if state.isDisconnected {
                    disconnectedView(state: state)
                } else if state.session != nil {
                    terminalView(state: state)
                } else {
                    connectingView
                }
            } else {
                connectingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await connectWhenReady()
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(86_400))
                }
            } onCancel: { [sessionState] in
                Task { @MainActor in
                    sessionState?.disconnect()
                }
            }
        }
    }

    @ViewBuilder
    private func terminalView(state: TerminalSessionState) -> some View {
        TerminalSurfaceView(context: state.terminalViewState)
            .background {
                TerminalFocusHelper(processManager: state.processManager)
            }
            .onAppear {
                guard let session = state.session else { return }
                let sessionId = ObjectIdentifier(session)
                guard configuredSessionId != sessionId else { return }
                state.terminalViewState.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(session)
                )
                configuredSessionId = sessionId
            }
    }

    private func disconnectedView(state: TerminalSessionState) -> some View {
        ContentUnavailableView {
            Label("Disconnected", systemImage: "terminal")
        } description: {
            if state.exitCode != 0 {
                Text(String(format: String(localized: "Process exited with code %d"), state.exitCode))
            }
        } actions: {
            Button {
                reconnect(state: state)
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var connectingView: some View {
        ProgressView("Connecting...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connection Lifecycle

    private func connectWhenReady() async {
        guard sessionState == nil else { return }

        let hasSSH = connection.sshTunnelMode != .disabled
        let tunnelReady = DatabaseManager.shared.session(for: connectionId)?.effectiveConnection != nil

        if hasSSH, !tunnelReady {
            let connected = await waitForSSHTunnel(timeout: .seconds(30))
            guard connected else {
                let state = TerminalSessionState(connectionId: connectionId, databaseType: connection.type)
                state.error = String(localized: "SSH tunnel did not connect within 30 seconds")
                self.sessionState = state
                return
            }
        }

        launchTerminalSession()
    }

    private func waitForSSHTunnel(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: .databaseDidConnect) {
                    if DatabaseManager.shared.session(for: self.connectionId)?.effectiveConnection != nil {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func launchTerminalSession() {
        guard sessionState == nil else { return }

        let state = TerminalSessionState(connectionId: connectionId, databaseType: connection.type)
        self.sessionState = state

        let password = ConnectionStorage.shared.loadPassword(for: connectionId)
        let activeDatabase = DatabaseManager.shared.session(for: connectionId)?.activeDatabase
            ?? connection.database

        state.connect(connection: connection, password: password, activeDatabase: activeDatabase)
    }

    private func reconnect(state: TerminalSessionState) {
        let password = ConnectionStorage.shared.loadPassword(for: connectionId)
        let activeDatabase = DatabaseManager.shared.session(for: connectionId)?.activeDatabase
            ?? connection.database

        state.reconnect(connection: connection, password: password, activeDatabase: activeDatabase)
    }
}

// MARK: - Focus & Input Helper

private struct TerminalFocusHelper: NSViewRepresentable {
    weak var processManager: TerminalProcessManager?

    func makeNSView(context: Context) -> TerminalFocusHelperView {
        let view = TerminalFocusHelperView()
        view.processManager = processManager
        return view
    }

    func updateNSView(_ nsView: TerminalFocusHelperView, context: Context) {
        nsView.processManager = processManager
    }
}

/// Bridges AppKit input handling for the embedded Ghostty terminal:
/// - Auto-focuses the terminal surface on appear
/// - Intercepts Cmd+V (paste) before AppKit's Edit menu captures it
/// - Provides right-click context menu for copy/paste
///
/// Cmd+C copy works natively via Ghostty's responder chain.
/// Cmd+A select-all is not supported by libghostty embedded mode.
private final class TerminalFocusHelperView: NSView {
    private weak var terminalView: NSView?
    weak var processManager: TerminalProcessManager?
    private var keyDownMonitor: Any?
    private var rightClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            removeMonitors()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            var ancestor: NSView? = self.superview?.superview
            while let current = ancestor {
                if let keyView = Self.firstKeyView(in: current, excluding: self) {
                    window.makeFirstResponder(keyView)
                    self.terminalView = keyView
                    self.installMonitors()
                    return
                }
                ancestor = current.superview
            }
        }
    }

    override func removeFromSuperview() {
        removeMonitors()
        super.removeFromSuperview()
    }

    // MARK: - Event Monitors

    private func installMonitors() {
        removeMonitors()

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let terminal = self.terminalView,
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.option),
                  terminal.window?.firstResponder === terminal
            else { return event }

            if event.charactersIgnoringModifiers == "v" {
                self.pasteFromClipboard()
                return nil
            }
            return event
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let terminal = self.terminalView,
                  terminal.window?.isKeyWindow == true
            else { return event }
            let point = terminal.convert(event.locationInWindow, from: nil)
            guard terminal.bounds.contains(point) else { return event }

            NSMenu.popUpContextMenu(self.buildContextMenu(), with: event, for: terminal)
            return nil
        }
    }

    private func removeMonitors() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(copySelection), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let paste = NSMenuItem(title: String(localized: "Paste"), action: #selector(pasteFromClipboard), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        menu.addItem(paste)

        return menu
    }

    @objc private func copySelection() {
        guard let terminal = terminalView, let window = terminal.window else { return }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8
        ) else { return }
        terminal.keyDown(with: event)
    }

    @objc private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        processManager?.write(Data(text.utf8))
    }

    // MARK: - Key View Discovery

    private static func firstKeyView(in view: NSView, excluding: NSView) -> NSView? {
        for subview in view.subviews where subview !== excluding {
            if subview.canBecomeKeyView {
                return subview
            }
            if let found = firstKeyView(in: subview, excluding: excluding) {
                return found
            }
        }
        return nil
    }
}
