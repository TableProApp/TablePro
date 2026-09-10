//
//  ScriptConnectGate.swift
//  TablePro
//

import Foundation

/// The confirmation a connect has to clear before a script can cause one.
///
/// A pre-connect script is arbitrary shell code stored with the connection, and
/// `DatabaseManager.ensureConnected` runs it. `PreConnectScriptPrompt` exists so no route to a
/// connect can run that code without a person seeing it first, and every route a person can take
/// asks: the connection list, a `tablepro://` link, and opening a table. A script is a route too, so
/// it asks as well.
///
/// Skipped only when the session is genuinely live. An installed driver is not the test: a session
/// the health monitor has marked unreachable or recovering keeps its driver by design, and
/// `connectionState` reports it as stored, so `ensureConnected` reconnects and runs the script again.
/// Asking on `driver != nil` would have stayed silent through exactly that reconnect.
@MainActor
internal enum ScriptConnectGate {
    internal static func authorizeConnect(connectionId: UUID) async throws {
        if case .live = DatabaseManager.shared.connectionState(connectionId) { return }

        guard let connection = ConnectionStorage.shared.loadConnections()
            .first(where: { $0.id == connectionId })
        else {
            throw ScriptingError.noSuchObject(String(localized: "No saved connection has that id."))
        }
        guard connection.hasPreConnectScript else { return }

        guard await PreConnectScriptPrompt.confirmIfNeeded(for: connection) else {
            throw ScriptingError.refused(
                String(localized: "The connection's pre-connect script was not approved.")
            )
        }
    }
}
