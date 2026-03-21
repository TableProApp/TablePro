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
    case pluginNotLoaded(String)

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason):
            return String(localized: "Invalid plugin bundle: \(reason)")
        case .signatureInvalid(let detail):
            return String(localized: "Plugin code signature verification failed: \(detail)")
        case .checksumMismatch:
            return String(localized: "Plugin checksum does not match expected value")
        case .incompatibleVersion(let required, let current):
            return String(localized: "Plugin requires PluginKit version \(required), but app provides version \(current)")
        case .cannotUninstallBuiltIn:
            return String(localized: "Built-in plugins cannot be uninstalled")
        case .notFound:
            return String(localized: "Plugin not found")
        case .noCompatibleBinary:
            return String(localized: "Plugin does not contain a compatible binary for this architecture")
        case .installFailed(let reason):
            return String(localized: "Plugin installation failed: \(reason)")
        case .pluginConflict(let existingName):
            return String(localized: "A built-in plugin \"\(existingName)\" already provides this bundle ID")
        case .appVersionTooOld(let minimumRequired, let currentApp):
            return String(localized: "Plugin requires app version \(minimumRequired) or later, but current version is \(currentApp)")
        case .downloadFailed(let reason):
            return String(localized: "Plugin download failed: \(reason)")
        case .pluginNotInstalled(let databaseType):
            return String(localized: "The \(databaseType) plugin is not installed. You can download it from the plugin marketplace.")
        case .incompatibleWithCurrentApp(let minimumRequired):
            return String(localized: "This plugin requires TablePro \(minimumRequired) or later")
        case .invalidDescriptor(let pluginId, let reason):
            return String(localized: "Plugin '\(pluginId)' has an invalid descriptor: \(reason)")
        case .pluginNotLoaded(let databaseType):
            return String(localized: "The \(databaseType) driver plugin is still loading. Please try again in a moment.")
        }
    }
}
