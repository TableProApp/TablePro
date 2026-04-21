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
        .onAppear { startTerminal() }
        .onDisappear {
            let state = sessionState
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                state?.disconnect()
            }
        }
    }

    @ViewBuilder
    private func terminalView(state: TerminalSessionState) -> some View {
        TerminalSurfaceView(context: state.terminalViewState)
            .background {
                TerminalFocusHelper()
            }
            .onAppear {
                if let session = state.session {
                    state.terminalViewState.configuration = TerminalSurfaceOptions(
                        backend: .inMemory(session)
                    )
                }
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

    private func startTerminal() {
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

// MARK: - Focus Helper

/// Makes the terminal surface first responder when it appears.
/// Follows the same pattern as SQLEditorCoordinator's auto-focus (50ms delay + makeFirstResponder).
private struct TerminalFocusHelper: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalFocusHelperView {
        TerminalFocusHelperView()
    }

    func updateNSView(_ nsView: TerminalFocusHelperView, context: Context) {}
}

private final class TerminalFocusHelperView: NSView {
    private weak var terminalView: NSView?
    private var rightClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            removeMonitor()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            var ancestor: NSView? = self.superview?.superview
            while let current = ancestor {
                if let keyView = Self.firstKeyView(in: current, excluding: self) {
                    window.makeFirstResponder(keyView)
                    self.terminalView = keyView
                    self.installRightClickMonitor()
                    return
                }
                ancestor = current.superview
            }
        }
    }

    override func removeFromSuperview() {
        removeMonitor()
        super.removeFromSuperview()
    }

    // MARK: - Right-Click Context Menu

    private func installRightClickMonitor() {
        removeMonitor()
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let terminal = self.terminalView else { return event }
            let locationInTerminal = terminal.convert(event.locationInWindow, from: nil)
            guard terminal.bounds.contains(locationInTerminal) else { return event }

            let menu = self.buildContextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: terminal)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(handleCopy), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = true
        menu.addItem(copy)

        let paste = NSMenuItem(title: String(localized: "Paste"), action: #selector(handlePaste), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = true
        menu.addItem(paste)

        menu.addItem(.separator())

        let selectAll = NSMenuItem(title: String(localized: "Select All"), action: #selector(handleSelectAll), keyEquivalent: "")
        selectAll.target = self
        selectAll.isEnabled = true
        menu.addItem(selectAll)

        return menu
    }

    @objc private func handleCopy() {
        simulateKeyEvent(characters: "c", modifiers: .command)
    }

    @objc private func handlePaste() {
        simulateKeyEvent(characters: "v", modifiers: .command)
    }

    @objc private func handleSelectAll() {
        simulateKeyEvent(characters: "a", modifiers: .command)
    }

    private func simulateKeyEvent(characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let terminal = terminalView, let window = terminal.window else { return }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ) else { return }
        terminal.keyDown(with: event)
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
