//
//  ConnectionRecoveryAction.swift
//  TablePro
//

import Foundation

internal enum ConnectionRecoveryAction: Equatable, Sendable {
    case installPlugin
    case openPluginSettings(pluginId: String?)
    case editConnection
    case openLocalNetworkSettings

    internal var title: String {
        switch self {
        case .installPlugin:
            return String(localized: "Install Plugin…")
        case .openPluginSettings:
            return String(localized: "Open Plugin Settings")
        case .editConnection:
            return String(localized: "Edit Connection…")
        case .openLocalNetworkSettings:
            return String(localized: "Open System Settings")
        }
    }

    internal var symbolName: String {
        switch self {
        case .installPlugin, .openPluginSettings:
            return "puzzlepiece.extension"
        case .editConnection:
            return "exclamationmark.triangle"
        case .openLocalNetworkSettings:
            return "network.badge.shield.half.filled"
        }
    }

    // A fix made in Settings leaves the connect itself to the user.
    internal var offersRetry: Bool {
        switch self {
        case .openPluginSettings, .openLocalNetworkSettings:
            return true
        case .installPlugin, .editConnection:
            return false
        }
    }
}
