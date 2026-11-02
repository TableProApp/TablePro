//
//  ScriptConnectGate.swift
//  TablePro
//

import Foundation

// Only `.live` skips the questions: a session marked unreachable keeps its driver and reconnects.
@MainActor
internal enum ScriptConnectGate {
    internal static func authorizeConnect(connectionId: UUID) async throws {
        if case .live = DatabaseManager.shared.connectionState(connectionId) { return }

        guard let connection = ConnectionStorage.shared.loadConnections()
            .first(where: { $0.id == connectionId })
        else {
            throw ScriptingError.noSuchObject(String(localized: "No saved connection has that id."))
        }
        guard await ConnectConsent.confirmIfNeeded(for: connection) else {
            throw ScriptingError.refused(
                String(localized: "The connection's environment variables, pre-connect script or SQLite extensions were not approved.")
            )
        }
    }
}
