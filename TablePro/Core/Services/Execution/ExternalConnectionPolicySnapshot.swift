//
//  ExternalConnectionPolicySnapshot.swift
//  TablePro
//

import Foundation

/// What a caller outside the app's own windows has to know about a connection before it may touch it.
///
/// The two policy fields come from different places, and which place is right is a property of how
/// each one is reconciled rather than a matter of taste.
///
/// Safe Mode comes from the live session, because `DatabaseManager.reconcileStoredRecord` pushes a
/// change onto the session through `setSafeModeLevel`, so the session carries the level in force now.
///
/// **External Clients comes from storage**, because nothing pushes it onto the session:
/// `adoptDisplayFields` reconciles `name`, `color` and `tagIds` and nothing else, so
/// `session.connection.externalAccess` is frozen at connect time. Reading it from the session meant
/// lowering an open connection from Read & Write to Read Only did nothing at all until the user
/// reconnected, on every surface that asks, while the settings pane reported the new level.
internal struct ExternalConnectionPolicySnapshot: Sendable {
    internal let connectionId: UUID
    internal let connectionName: String
    internal let databaseType: DatabaseType
    internal let safeModeLevel: SafeModeLevel
    internal let externalAccess: ExternalAccessLevel
    /// The database in force: the one the session is browsing when connected, the saved one when not.
    internal let databaseName: String
    /// The database the connection was saved with, which is not the one in force once the user has
    /// switched. Kept alongside because an error redactor has to hide both spellings.
    internal let storedDatabaseName: String
    internal let host: String
    internal let port: Int
    internal let username: String

    @MainActor
    internal static func resolve(connectionId: UUID) throws -> ExternalConnectionPolicySnapshot {
        let stored = ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }
        switch DatabaseManager.shared.connectionState(connectionId) {
        case .live(_, let session):
            return make(
                connectionId: connectionId,
                connection: session.connection,
                databaseName: session.resolvedBrowseDatabase,
                /// A session whose record has been deleted keeps no claim to a level, so it falls to
                /// the most restrictive one rather than to whatever it was granted at connect time.
                externalAccess: stored?.externalAccess ?? .blocked
            )
        case .stored(let connection):
            return make(
                connectionId: connectionId,
                connection: connection,
                databaseName: connection.database,
                externalAccess: connection.externalAccess
            )
        case .unknown:
            throw DatabaseAccessError.notFound(
                String(localized: "No saved connection has that id.")
            )
        }
    }

    private static func make(
        connectionId: UUID,
        connection: DatabaseConnection,
        databaseName: String,
        externalAccess: ExternalAccessLevel
    ) -> ExternalConnectionPolicySnapshot {
        ExternalConnectionPolicySnapshot(
            connectionId: connectionId,
            connectionName: connection.name,
            databaseType: connection.type,
            safeModeLevel: connection.safeModeLevel,
            externalAccess: externalAccess,
            databaseName: databaseName,
            storedDatabaseName: connection.database,
            host: connection.host,
            port: connection.port,
            username: connection.username
        )
    }

    /// Values worth keeping out of an error a caller outside the app will read, log or store.
    internal var redactionSecrets: [String] {
        [host, username, databaseName, storedDatabaseName, String(port)].filter { !$0.isEmpty }
    }
}
