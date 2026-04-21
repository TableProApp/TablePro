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
            .contextMenu {
                terminalContextMenu(state: state)
            }
            .onAppear {
                if let session = state.session {
                    state.terminalViewState.configuration = TerminalSurfaceOptions(
                        backend: .inMemory(session)
                    )
                }
            }
    }

    @ViewBuilder
    private func terminalContextMenu(state: TerminalSessionState) -> some View {
        Button("Copy") {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("c", modifiers: .command)

        Button("Paste") {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("v", modifiers: .command)

        Divider()

        Button("Select All") {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("a", modifiers: .command)

        Button("Clear Terminal") {
            clearTerminal(state: state)
        }

        Divider()

        Button("Search") {}
            .disabled(true)
            .help("Coming soon")
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

    private func clearTerminal(state: TerminalSessionState) {
        // Send Ctrl+L (form feed) to clear the terminal screen
        let ctrlL = Data([0x0C])
        state.processManager?.write(ctrlL)
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            var ancestor: NSView? = self.superview?.superview
            while let current = ancestor {
                if let keyView = Self.firstKeyView(in: current, excluding: self) {
                    window.makeFirstResponder(keyView)
                    return
                }
                ancestor = current.superview
            }
        }
    }

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
