//
//  PluginManager+Lifecycle.swift
//  TablePro
//

import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

extension PluginManager {
    func setEnabled(_ enabled: Bool, pluginId: String) {
        guard let index = plugins.firstIndex(where: { $0.id == pluginId }) else { return }

        plugins[index].isEnabled = enabled

        var disabled = disabledPluginIds
        if enabled {
            disabled.remove(pluginId)
        } else {
            disabled.insert(pluginId)
        }
        disabledPluginIds = disabled

        if enabled {
            if let principalClass = plugins[index].bundle.principalClass as? any TableProPlugin.Type {
                let instance = principalClass.init()
                registerCapabilities(instance, pluginId: pluginId)
            }
        } else {
            unregisterCapabilities(pluginId: pluginId)
        }

        queryBuildingDriverCache.removeAll()
        Self.logger.info("Plugin '\(pluginId)' \(enabled ? "enabled" : "disabled")")
    }

    func uninstallPlugin(id: String) async throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginError.notFound
        }

        let entry = plugins[index]

        guard entry.source == .userInstalled else {
            throw PluginError.cannotUninstallBuiltIn
        }

        unregisterCapabilities(pluginId: id)
        entry.bundle.unload()
        plugins.remove(at: index)

        removeRegistryMetadata(for: entry.url)

        let fm = FileManager.default
        if fm.fileExists(atPath: entry.url.path) {
            try fm.removeItem(at: entry.url)
        }

        PluginSettingsStorage(pluginId: id).removeAll()

        var disabled = disabledPluginIds
        disabled.remove(id)
        disabledPluginIds = disabled

        if stagedUpdates[id] != nil {
            await discardStagedUpdate(pluginId: id)
        }

        queryBuildingDriverCache.removeAll()
        refreshRegistryUpdateSet()

        Self.logger.info("Uninstalled plugin '\(id)'")
        needsRestart = true
    }
}
