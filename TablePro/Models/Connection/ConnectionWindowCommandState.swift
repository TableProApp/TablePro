//
//  ConnectionWindowCommandState.swift
//  TablePro
//

import Foundation

/// What the menu bar needs to know about the key window's connection. A value, not the controller,
/// because the registry that publishes it is observed by the menus: holding the controller would
/// leave Disconnect enabled after a disconnect, since the reference never changes when the phase does.
internal struct ConnectionWindowCommandState: Equatable, Sendable {
    /// Which window published this. Several windows can share a connection, so the connection id
    /// cannot answer "is this mine to clear": a background tab of the same connection closing used
    /// to wipe the key window's state and leave both commands disabled with nothing to restore them.
    internal let owner: ObjectIdentifier
    internal let connectionId: UUID
    internal let connectionName: String
    internal let canDisconnect: Bool
    internal let canReconnect: Bool
}
