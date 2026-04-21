//
//  TerminalTabContentView.swift
//  TablePro
//

import GhosttyTerminal
import os
import SwiftUI

struct TerminalTabContentView: View {
    let tab: QueryTab
    let connection: DatabaseConnection
    let connectionId: UUID

    @State private var sessionState: TerminalSessionState?

    var body: some View {
        ZStack {
            if let state = sessionState {
                if state.error != nil {
                    TerminalErrorView(error: state.error!, databaseType: connection.type)
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
    private static let logger = Logger(subsystem: "com.TablePro", category: "TerminalFocus")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            Self.logger.debug("viewDidMoveToWindow: no window")
            return
        }
        Self.logger.debug("viewDidMoveToWindow: window=\(window.title, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else {
                Self.logger.debug("focus: self deallocated")
                return
            }
            Self.logger.debug("focus: superview=\(String(describing: self.superview?.className), privacy: .public)")
            Self.dumpViewHierarchy(self.superview, depth: 0)

            if let parent = self.superview,
               let keyView = Self.firstKeyView(in: parent, excluding: self) {
                Self.logger.info("focus: making firstResponder → \(keyView.className, privacy: .public)")
                let success = window.makeFirstResponder(keyView)
                Self.logger.info("focus: makeFirstResponder result=\(success)")
            } else {
                Self.logger.warning("focus: no keyView found, trying window.contentView")
                Self.dumpViewHierarchy(window.contentView, depth: 0)
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

    private static func dumpViewHierarchy(_ view: NSView?, depth: Int) {
        guard let view, depth < 6 else { return }
        let indent = String(repeating: "  ", count: depth)
        let accepts = view.acceptsFirstResponder ? "✓FR" : ""
        let canKey = view.canBecomeKeyView ? "✓KV" : ""
        let frame = "(\(Int(view.frame.width))×\(Int(view.frame.height)))"
        logger.debug("\(indent, privacy: .public)\(view.className, privacy: .public) \(frame, privacy: .public) \(accepts, privacy: .public) \(canKey, privacy: .public)")
        for subview in view.subviews {
            dumpViewHierarchy(subview, depth: depth + 1)
        }
    }
}
