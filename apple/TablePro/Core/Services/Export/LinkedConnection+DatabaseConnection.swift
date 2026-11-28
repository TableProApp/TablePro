//
//  LinkedConnection+DatabaseConnection.swift
//  TablePro
//

import Foundation
import TableProImport
import TableProPluginKit

internal extension LinkedConnection {
    @MainActor
    func databaseConnection() -> DatabaseConnection {
        DatabaseConnection(
            importing: connection,
            id: id,
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { SSHProfileStorage.shared.profile(for: $0) != nil }
        ).sharedCopy(from: .linkedFolder)
    }
}

internal extension DatabaseConnection {
    // A linked folder's or a team's row is never saved, so it asks for its password unless the team's envelopes held one.
    @MainActor
    func sharedCopy(from origin: ConnectionOrigin, holdsPassword: Bool = false) -> DatabaseConnection {
        var copy = self
        copy.promptForPassword = !holdsPassword && Self.signsInWithPassword(copy)
        copy.origin = origin
        return copy
    }

    @MainActor
    private static func signsInWithPassword(_ connection: DatabaseConnection) -> Bool {
        let pluginManager = PluginManager.shared
        guard pluginManager.connectionMode(for: connection.type) != .fileBased else { return false }
        return !pluginManager.hidesPassword(for: connection)
    }
}
