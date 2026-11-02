//
//  LinkedConnection+DatabaseConnection.swift
//  TablePro
//

import Foundation
import TableProImport
import TableProPluginKit

internal extension LinkedConnection {
    @MainActor
    func databaseConnection(origin: ConnectionOrigin = .linkedFolder) -> DatabaseConnection {
        var built = DatabaseConnection(
            importing: connection,
            id: id,
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { SSHProfileStorage.shared.profile(for: $0) != nil }
        )
        built.promptForPassword = Self.signsInWithPassword(built)
        built.origin = origin
        return built
    }

    @MainActor
    private static func signsInWithPassword(_ connection: DatabaseConnection) -> Bool {
        let pluginManager = PluginManager.shared
        guard pluginManager.connectionMode(for: connection.type) != .fileBased else { return false }
        return !pluginManager.hidesPassword(for: connection)
    }
}
