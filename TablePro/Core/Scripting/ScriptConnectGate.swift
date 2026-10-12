//
//  ScriptConnectGate.swift
//  TablePro
//

import Foundation

/// The question a script's connect asks before it reaches `DatabaseManager`: SQLite extensions this
/// Mac has not approved for the connection. The pre-connect script is asked about at the connect
/// itself, by `PreConnectScriptConsent`, the same as for every other caller.
///
/// Skipped only when the session is genuinely live. An installed driver is not the test: a session
/// the health monitor has marked unreachable or recovering keeps its driver by design, and
/// `connectionState` reports it as stored, so `ensureConnected` reconnects.
@MainActor
internal enum ScriptConnectGate {
    internal static func authorizeConnect(connectionId: UUID) async throws {
        if case .live = DatabaseManager.shared.connectionState(connectionId) { return }

        guard let connection = ConnectionStorage.shared.loadConnections()
            .first(where: { $0.id == connectionId })
        else {
            throw ScriptingError.noSuchObject(String(localized: "No saved connection has that id."))
        }
        guard await LoadableExtensionPrompt.confirmIfNeeded(for: connection) else {
            throw ScriptingError.refused(
                String(localized: "The connection's SQLite extensions were not approved.")
            )
        }
    }
}
