//
//  ScriptConnectionCommands.swift
//  TablePro
//

import AppKit
import Foundation

/// `connect connection "prod"`
///
/// Opens the session without opening a window, so a script can read from a connection the user does
/// not have on screen. Connecting can still put a password or passphrase prompt in front of the
/// person, which is correct: the alternative is a script silently failing on every connection whose
/// secret is not in the keychain.
@objc(TPScriptConnectCommand)
internal final class ScriptConnectCommand: ScriptCommand {
    private let bridge = DatabaseAccessBridge()

    @MainActor
    override internal func run() async throws -> Any? {
        let connection = try requiredReceiver(ScriptConnection.self)
        try await ScriptConnectGate.authorizeConnect(connectionId: connection.connectionId)
        _ = try await bridge.connect(connectionId: connection.connectionId)
        return ScriptingSnapshot.connection(withId: connection.connectionId)
    }
}

/// `disconnect connection "prod"`
///
/// Through `ConnectionDisconnectAction`, which is the one path a requested disconnect takes, so a
/// script gets the same unsaved-work confirmation the menu bar and the rail get and the session ends
/// as one the user asked to end. Tearing the session down directly would discard pending grid edits
/// with nothing said, and would leave the window treating a deliberate disconnect as a lost one.
@objc(TPScriptDisconnectCommand)
internal final class ScriptDisconnectCommand: ScriptCommand {
    @MainActor
    override internal func run() async throws -> Any? {
        let connection = try requiredReceiver(ScriptConnection.self)
        guard case .live = DatabaseManager.shared.connectionState(connection.connectionId) else {
            throw ScriptingError.failed(String(localized: "The connection is not open."))
        }

        await ConnectionDisconnectAction.disconnect(
            connectionId: connection.connectionId,
            connectionName: connection.name,
            presentingWindow: NSApp.keyWindow
        )

        if case .live = DatabaseManager.shared.connectionState(connection.connectionId) {
            throw ScriptingError.refused(String(localized: "The disconnect was cancelled."))
        }
        return ScriptingSnapshot.connection(withId: connection.connectionId)
    }
}

/// `show connection "prod"`
///
/// Brings the connection's window forward, opening one if it has none. This is the deep link the URL
/// scheme already offers, reachable from a script that also wants a value back afterwards.
@objc(TPScriptShowConnectionCommand)
internal final class ScriptShowConnectionCommand: ScriptCommand {
    @MainActor
    override internal func run() async throws -> Any? {
        let connection = try requiredReceiver(ScriptConnection.self)
        try await TabRouter.shared.route(.openConnection(connection.connectionId))
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        return ScriptingSnapshot.connection(withId: connection.connectionId)
    }
}
