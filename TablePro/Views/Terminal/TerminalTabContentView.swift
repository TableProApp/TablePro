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
        Group {
            if let state = sessionState, state.error == nil {
                terminalView(state: state)
            } else if let error = sessionState?.error {
                TerminalErrorView(error: error, databaseType: connection.type)
            } else {
                connectingView
            }
        }
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
        if let session = state.session {
            TerminalSurfaceView(context: state.terminalViewState)
                .onAppear {
                    state.terminalViewState.configuration = TerminalSurfaceOptions(
                        backend: .inMemory(session)
                    )
                }
        } else {
            connectingView
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
}
