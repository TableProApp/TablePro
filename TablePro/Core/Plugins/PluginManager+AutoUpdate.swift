//
//  PluginManager+AutoUpdate.swift
//  TablePro
//

import Foundation
import os

extension PluginManager {
    func autoUpdateRejectedPlugins() async {
        let outdated = rejectedPlugins.filter(\.isOutdated)
        guard !outdated.isEmpty else { return }

        Self.logger.info("Attempting auto-update for \(outdated.count) outdated plugin(s)")

        let registryClient = RegistryClient.shared
        await registryClient.fetchManifest()

        guard let manifest = registryClient.manifest else {
            Self.logger.warning("Auto-update skipped: registry manifest unavailable")
            return
        }

        var stillFailed: [RejectedPlugin] = []

        for plugin in outdated {
            let lookupId = plugin.registryId ?? plugin.bundleId

            guard let lookupId,
                  let registryPlugin = manifest.plugins.first(where: { $0.id == lookupId }) else {
                Self.logger.warning("Auto-update skipped for '\(plugin.name)': no matching registry plugin")
                stillFailed.append(plugin)
                continue
            }

            do {
                _ = try await updateFromRegistry(registryPlugin, existingPluginLoaded: false) { _ in }
                Self.logger.info("Auto-updated plugin '\(plugin.name)' to v\(registryPlugin.version)")
            } catch {
                Self.logger.error("Auto-update failed for '\(plugin.name)': \(error.localizedDescription)")
                stillFailed.append(RejectedPlugin(
                    url: plugin.url,
                    bundleId: plugin.bundleId,
                    registryId: plugin.registryId,
                    name: plugin.name,
                    reason: error.localizedDescription,
                    isOutdated: plugin.isOutdated
                ))
            }
        }

        let updatedCount = outdated.count - stillFailed.count
        if updatedCount > 0 {
            Self.logger.info("Auto-updated \(updatedCount) plugin(s) from registry")
        }

        let processedURLs = Set(outdated.map(\.url))
        rejectedPlugins = rejectedPlugins.filter { !processedURLs.contains($0.url) } + stillFailed
    }

    func registryUpdate(for pluginId: String) -> RegistryPlugin? {
        guard let manifest = RegistryClient.shared.manifest else { return nil }
        guard let installed = plugins.first(where: { $0.id == pluginId }) else { return nil }
        guard let registryPlugin = manifest.plugins.first(where: { $0.id == pluginId }) else { return nil }
        guard registryPlugin.category != .theme else { return nil }
        return registryPlugin.version.compare(installed.version, options: .numeric) == .orderedDescending
            ? registryPlugin : nil
    }
}
