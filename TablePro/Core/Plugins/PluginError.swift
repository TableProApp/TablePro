//
//  PluginError.swift
//  TablePro
//

import Foundation

enum PluginError: LocalizedError {
    case invalidBundle(String)
    case signatureInvalid(detail: String)
    case checksumMismatch
    case incompatibleVersion(required: Int, current: Int)
    case pluginOutdated(pluginVersion: Int, requiredVersion: Int)
    case cannotUninstallBuiltIn
    case notFound
    case noCompatibleBinary
    case installFailed(String)
    case pluginConflict(existingName: String)
    case appVersionTooOld(minimumRequired: String, currentApp: String)
    case downloadFailed(String)
    case pluginNotInstalled(String)
    case incompatibleWithCurrentApp(minimumRequired: String)
    case invalidDescriptor(pluginId: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason):
            return String(format: String(localized: "Invalid plugin bundle: %@"), reason)
        case .signatureInvalid(let detail):
            return String(format: String(localized: "Plugin code signature verification failed: %@"), detail)
        case .checksumMismatch:
            return String(localized: "Plugin checksum does not match expected value")
        case .incompatibleVersion(let required, let current):
            return String(format: String(localized: "Plugin requires PluginKit version %d, but app provides version %d"), required, current)
        case .pluginOutdated(let pluginVersion, let requiredVersion):
            let format = String(localized: "Plugin was built with PluginKit version %d, but version %d is required. Please update the plugin.")
            return String(format: format, pluginVersion, requiredVersion)
        case .cannotUninstallBuiltIn:
            return String(localized: "Built-in plugins cannot be uninstalled")
        case .notFound:
            return String(localized: "Plugin not found")
        case .noCompatibleBinary:
            return String(localized: "Plugin does not contain a compatible binary for this architecture")
        case .installFailed(let reason):
            return String(format: String(localized: "Plugin installation failed: %@"), reason)
        case .pluginConflict(let existingName):
            return String(format: String(localized: "A built-in plugin \"%@\" already provides this bundle ID"), existingName)
        case .appVersionTooOld(let minimumRequired, let currentApp):
            return String(format: String(localized: "Plugin requires app version %@ or later, but current version is %@"), minimumRequired, currentApp)
        case .downloadFailed(let reason):
            return String(format: String(localized: "Plugin download failed: %@"), reason)
        case .pluginNotInstalled(let databaseType):
            return String(format: String(localized: "The %@ plugin is not installed. You can download it from the plugin marketplace."), databaseType)
        case .incompatibleWithCurrentApp(let minimumRequired):
            return String(format: String(localized: "This plugin requires TablePro %@ or later"), minimumRequired)
        case .invalidDescriptor(let pluginId, let reason):
            return String(format: String(localized: "Plugin '%@' has an invalid descriptor: %@"), pluginId, reason)
        }
    }

    var isOutdated: Bool {
        if case .pluginOutdated = self { return true }
        return false
    }
}
