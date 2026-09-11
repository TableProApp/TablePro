//
//  PluginManager+DriverAvailability.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum DriverUnavailability: Equatable, Sendable {
    case unknownType
    case disabled(pluginId: String, pluginName: String)
    case failedToLoad(pluginId: String?, pluginName: String, reason: String?)
    case outdated(reason: String)
    case notInstalled
}

extension PluginManager {
    func installedEntry(servingTypeId typeId: String) -> PluginEntry? {
        plugins.first { entry in
            entry.databaseTypeId == typeId || entry.additionalTypeIds.contains(typeId)
        }
    }

    func driverUnavailability(
        for databaseType: DatabaseType,
        registryManifest: RegistryManifest? = RegistryClient.shared.manifest
    ) -> DriverUnavailability {
        let typeId = databaseType.pluginTypeId
        if let entry = installedEntry(servingTypeId: typeId) {
            guard entry.isEnabled else {
                return .disabled(pluginId: entry.id, pluginName: entry.name)
            }
            let rejection = rejectedPlugins.first { $0.providedDatabaseTypeIds.contains(typeId) }
            return .failedToLoad(pluginId: entry.id, pluginName: entry.name, reason: rejection?.reason)
        }
        if let rejection = rejectedPlugins.first(where: { $0.providedDatabaseTypeIds.contains(typeId) }) {
            if rejection.isOutdated {
                return .outdated(reason: rejection.reason)
            }
            return .failedToLoad(pluginId: rejection.bundleId, pluginName: rejection.name, reason: rejection.reason)
        }
        if databaseType.isDownloadablePlugin || Self.registryPlugin(forTypeId: typeId, in: registryManifest) != nil {
            return .notInstalled
        }
        guard PluginMetadataRegistry.shared.snapshot(for: databaseType) != nil else {
            return .unknownType
        }
        return .failedToLoad(pluginId: nil, pluginName: Self.registryDisplayName(of: databaseType), reason: nil)
    }

    nonisolated static func registryDisplayName(of databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.displayName ?? databaseType.rawValue
    }

    func driverUnavailableError(for databaseType: DatabaseType) -> PluginError {
        switch driverUnavailability(for: databaseType) {
        case .unknownType:
            return .unknownDatabaseType(databaseType.rawValue)
        case .disabled(let pluginId, let pluginName):
            return .pluginDisabled(pluginId: pluginId, pluginName: pluginName)
        case .failedToLoad(let pluginId, let pluginName, let reason):
            return .pluginLoadFailed(pluginId: pluginId, pluginName: pluginName, reason: reason)
        case .outdated(let reason):
            return .pluginUpdateUnavailable(reason: reason)
        case .notInstalled:
            return .pluginNotInstalled(Self.registryDisplayName(of: databaseType))
        }
    }
}
