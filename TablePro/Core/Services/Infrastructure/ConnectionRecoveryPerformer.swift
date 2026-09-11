//
//  ConnectionRecoveryPerformer.swift
//  TablePro
//

import Foundation

internal struct PendingConnectionRecovery {
    let action: ConnectionRecoveryAction
    let connection: DatabaseConnection
}

@MainActor
internal enum ConnectionRecoveryPerformer {
    internal static func canEdit(_ connection: DatabaseConnection) -> Bool {
        ConnectionStorage.shared.loadConnections().contains { $0.id == connection.id }
    }

    internal static func perform(
        _ action: ConnectionRecoveryAction,
        for connection: DatabaseConnection,
        retry: @escaping @MainActor () -> Void
    ) {
        switch action {
        case .installPlugin:
            WelcomeRouter.shared.routePluginInstall(connection)
        case .enablePlugin(let pluginId):
            PluginManager.shared.setEnabled(true, pluginId: pluginId)
            retry()
        case .openPluginSettings(let pluginId):
            PluginsSettingsNavigation.shared.reveal(pluginId: pluginId)
            WindowOpener.shared.openSettings(tab: .plugins)
        case .editConnection:
            WindowOpener.shared.openConnectionForm(editing: connection.id)
        }
    }
}
