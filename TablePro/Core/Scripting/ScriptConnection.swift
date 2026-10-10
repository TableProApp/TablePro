//
//  ScriptConnection.swift
//  TablePro
//

import AppKit
import Foundation

/// A value snapshot rebuilt on every event, so it is always current. `objectSpecifier` is by
/// unique ID because a name is editable and need not be unique.
///
/// No credential and no user name. With host and port, a user name would hand any app with
/// Automation permission the target of a password spray.
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
    @objc internal let color: FourCharCode
    @objc internal let groupPath: ScriptTextList
    @objc internal let groupColor: FourCharCode
    @objc internal let tagNames: ScriptTextList

    internal let connectionId: UUID

    internal init(listing: ExternalConnectionListing) {
        self.connectionId = listing.id
        self.uniqueId = listing.id.uuidString
        self.name = listing.name
        self.databaseType = listing.databaseType
        self.host = listing.host
        self.port = listing.port
        self.currentDatabase = listing.database
        self.currentSchema = listing.schema
        self.isConnected = listing.isConnected
        self.safeMode = ScriptEnumerations.code(for: listing.safeModeLevel)
        self.externalAccess = ScriptEnumerations.code(for: listing.externalAccess)
        self.color = ScriptEnumerations.code(for: listing.color)
        self.groupPath = ScriptTextList(listing.group?.path ?? [])
        self.groupColor = ScriptEnumerations.code(for: listing.group?.color ?? .none)
        self.tagNames = ScriptTextList(listing.tags.map(\.name))
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
