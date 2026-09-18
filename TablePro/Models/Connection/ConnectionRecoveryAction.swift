//
//  ConnectionRecoveryAction.swift
//  TablePro
//

import Foundation

internal enum ConnectionRecoveryAction: Equatable, Sendable {
    case installPlugin
    case enablePlugin(pluginId: String)
    case openPluginSettings(pluginId: String?)
    case editConnection

    internal var title: String {
        switch self {
        case .installPlugin:
            return String(localized: "Install Plugin…")
        case .enablePlugin:
            return String(localized: "Enable Plugin")
        case .openPluginSettings:
            return String(localized: "Open Plugin Settings")
        case .editConnection:
            return String(localized: "Edit Connection…")
        }
    }

    internal var symbolName: String {
        switch self {
        case .installPlugin, .enablePlugin, .openPluginSettings:
            return "puzzlepiece.extension"
        case .editConnection:
            return "exclamationmark.triangle"
        }
    }

    internal var offersRetry: Bool {
        if case .openPluginSettings = self { return true }
        return false
    }
}
