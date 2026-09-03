//
//  ScriptConnection.swift
//  TablePro
//

import AppKit
import Foundation

/// One saved connection, as a script sees it.
///
/// A value snapshot rather than a live handle. Cocoa re-resolves `connection "prod"` on every event,
/// so a fresh instance per event is always current, and nothing here outlives the event that built
/// it. Identity across events comes from `uniqueId`, which is why `objectSpecifier` is a unique-ID
/// specifier: a name is editable and need not be unique, so a reference built on one would start
/// pointing somewhere else the moment the user renamed a connection.
///
/// Nothing on this object is a credential, and the account name is absent too. A password, an SSH
/// key, a password command and every plugin secure field would obviously not belong here; the user
/// name is the less obvious one, and it is left out because `list_connections` leaves it out and
/// `MCPErrorRedactor` treats it as a secret. Handing it to every app with Automation permission,
/// for every connection the user has never opened, would complete the target tuple for a password
/// spray against those servers on a weaker gate than the one MCP asks for.
@objc(TPScriptConnection)
internal final class ScriptConnection: NSObject, ScriptCommandReceiving {
    @objc internal let uniqueId: String
    @objc internal let name: String
    @objc internal let databaseType: String
    @objc internal let host: String
    @objc internal let port: Int
    @objc internal let currentDatabase: String
    @objc internal let currentSchema: String?
    @objc internal let isConnected: Bool
    @objc internal let safeMode: FourCharCode
    @objc internal let externalAccess: FourCharCode

    internal let connectionId: UUID

    internal init(connection: DatabaseConnection, session: ConnectionSession?) {
        self.connectionId = connection.id
        self.uniqueId = connection.id.uuidString
        self.name = connection.name
        self.databaseType = connection.type.rawValue
        self.host = connection.host
        self.port = connection.port
        self.currentDatabase = session?.resolvedBrowseDatabase ?? connection.database
        self.currentSchema = session?.browseSchema
        self.isConnected = session?.reportedStatus.isConnected ?? false
        self.safeMode = ScriptEnumerations.code(for: connection.safeModeLevel)
        self.externalAccess = ScriptEnumerations.code(for: connection.externalAccess)
        super.init()
    }

    /// Only the connection's id crosses onto the main actor. Handing the whole object over would
    /// mean sending a non-`Sendable` class into another isolation domain, which is the one thing
    /// the compiler will not let a snapshot type do.
    @objc internal var scriptTabs: [ScriptTab] {
        let connectionId = connectionId
        return MainActor.assumeIsolated {
            ScriptingBox(ScriptingSnapshot.tabs(forConnection: connectionId))
        }.value
    }

    @objc internal func valueInScriptTabs(withUniqueID id: Any) -> ScriptTab? {
        guard let wanted = ScriptingSnapshot.uuid(from: id) else { return nil }
        return scriptTabs.first { $0.tabId == wanted }
    }

    @objc internal func valueInScriptTabs(withName name: String) -> ScriptTab? {
        scriptTabs.first { $0.name == name }
    }

    @objc internal func handleConnectCommand(_ command: NSScriptCommand) -> Any? {
        beginScriptCommand(command)
    }

    @objc internal func handleDisconnectCommand(_ command: NSScriptCommand) -> Any? {
        beginScriptCommand(command)
    }

    @objc internal func handleShowCommand(_ command: NSScriptCommand) -> Any? {
        beginScriptCommand(command)
    }

    override internal var objectSpecifier: NSScriptObjectSpecifier? {
        let uniqueId = uniqueId
        return MainActor.assumeIsolated {
            ScriptingBox(ScriptingSpecifiers.connection(uniqueId: uniqueId))
        }.value
    }
}
