import AppKit

internal struct PendingConnectionRecovery {
    let action: ConnectionRecoveryAction
    let connection: DatabaseConnection
}

@MainActor
internal enum ConnectionRecoveryPerformer {
    // macOS 27 ignores the Local Network anchor and opens Privacy & Security, one row above it.
    private static let localNetworkSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )

    internal static func canEdit(_ connection: DatabaseConnection) -> Bool {
        ConnectionStorage.shared.loadConnections().contains { $0.id == connection.id }
    }

    internal static func perform(
        _ action: ConnectionRecoveryAction,
        for connection: DatabaseConnection,
        opener: WindowOpener = .shared
    ) {
        switch action {
        case .installPlugin:
            WelcomeRouter.shared.routePluginInstall(connection)
        case .openPluginSettings(let pluginId):
            opener.openSettings(revealingPlugin: pluginId)
        case .editConnection:
            // A connect refused over its own settings (an SSL mode the driver lacks, an extension) shows as an issue there.
            opener.openConnectionForm(editing: connection.id, facet: .firstIssue)
        case .openLocalNetworkSettings:
            guard let url = localNetworkSettingsURL else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
