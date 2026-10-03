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
        var built = ConnectionExportService.buildDatabaseConnection(
            id: id,
            from: connection,
            name: connection.name,
            tagIdsByName: [:],
            groupIdsByName: [:]
        )
        built.promptForPassword = Self.signsInWithPassword(built)
        return built
    }

    @MainActor
    private static func signsInWithPassword(_ connection: DatabaseConnection) -> Bool {
        let pluginManager = PluginManager.shared
        guard pluginManager.connectionMode(for: connection.type) != .fileBased else { return false }
        return !pluginManager.hidesPassword(for: connection)
    }
}
