//
//  PluginError.swift
//  TablePro
//

import Foundation

enum PluginError: LocalizedError {
    case invalidBundle(String)
    case signatureInvalid(detail: String)
    case developerNotTrusted(identity: PluginDeveloperIdentity)
    case checksumMismatch
    case incompatibleVersion(required: Int, current: Int)
    case pluginOutdated(pluginVersion: Int, requiredVersion: Int)
    case cannotUninstallBuiltIn
    case notFound
    case registryUnreachable
    case noCompatibleBinary
    case installFailed(String)
    case pluginConflict(existingName: String)
    case appVersionTooOld(minimumRequired: String, currentApp: String)
    case downloadFailed(String)
    case pluginNotInstalled(String)
    case pluginUpdateUnavailable(reason: String)
    case incompatibleWithCurrentApp(minimumRequired: String)
    case invalidDescriptor(pluginId: String, reason: String)
    case unknownDatabaseType(String)
    case pluginDisabled(pluginId: String, pluginName: String)
    case pluginLoadFailed(pluginId: String?, pluginName: String, reason: String?)
    case pluginInstallFailed(databaseType: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason):
            return String(format: String(localized: "Invalid plugin bundle: %@"), reason)
        case .signatureInvalid(let detail):
            return String(format: String(localized: "Plugin code signature verification failed: %@"), detail)
        case .developerNotTrusted(let identity):
            return String(
                format: String(localized: "This plugin is signed by %@, a developer you have not trusted yet."),
                identity.name
            )
        case .checksumMismatch:
            return String(localized: "Plugin checksum does not match expected value")
        case .incompatibleVersion(let required, let current):
            return String(format: String(localized: "Plugin requires PluginKit version %d, but app provides version %d"), required, current)
        case .pluginOutdated(let pluginVersion, let requiredVersion):
            let format = String(localized: "Plugin was built for PluginKit version %d; this release of TablePro needs version %d.")
            return String(format: format, pluginVersion, requiredVersion)
        case .cannotUninstallBuiltIn:
            return String(localized: "Built-in plugins cannot be uninstalled")
        case .notFound:
            return String(localized: "Plugin not found")
        case .registryUnreachable:
            return String(localized: "Couldn't reach the plugin registry. Check your connection and try again.")
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
        case .pluginUpdateUnavailable(let reason):
            return reason
        case .incompatibleWithCurrentApp(let minimumRequired):
            return String(format: String(localized: "This plugin requires TablePro %@ or later"), minimumRequired)
        case .invalidDescriptor(let pluginId, let reason):
            return String(format: String(localized: "Plugin '%@' has an invalid descriptor: %@"), pluginId, reason)
        case .unknownDatabaseType(let databaseType):
            return String(format: String(localized: "TablePro doesn't recognize the database type “%@”."), databaseType)
        case .pluginDisabled(_, let pluginName):
            return String(format: String(localized: "The %@ plugin is turned off."), pluginName)
        case .pluginLoadFailed(_, let pluginName, _):
            return String(format: String(localized: "The %@ plugin could not be loaded."), pluginName)
        case .pluginInstallFailed(let databaseType, let reason):
            return String(format: String(localized: "The %1$@ plugin could not be installed: %2$@"), databaseType, reason)
        }
    }

    var failureReason: String? {
        switch self {
        case .pluginLoadFailed(_, _, let reason):
            return reason
        default:
            return nil
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unknownDatabaseType:
            return String(localized: "Edit the connection and choose its database type.")
        case .pluginDisabled:
            return String(localized: "Turn the plugin on to connect.")
        case .pluginLoadFailed:
            return String(localized: "Update or reinstall the plugin in Settings > Plugins.")
        case .pluginInstallFailed:
            return String(localized: "Try again, or install the plugin from Settings > Plugins.")
        default:
            return nil
        }
    }

    var isOutdated: Bool {
        if case .pluginOutdated = self { return true }
        return false
    }

    var isPermanentReconciliationFailure: Bool {
        switch self {
        case .noCompatibleBinary, .incompatibleVersion, .incompatibleWithCurrentApp, .appVersionTooOld:
            return true
        default:
            return false
        }
    }
}
