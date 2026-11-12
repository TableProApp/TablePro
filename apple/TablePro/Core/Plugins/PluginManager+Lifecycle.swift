import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

extension PluginManager {
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
        removeStagedUpdate(pluginId: id)

        queryBuildingDriverCache.removeAll()

        Self.logger.info("Uninstalled plugin '\(id)'")
        needsRestart = true
    }

    // Only a bundle in the user's plugins folder: one inside the app breaks its seal, and no registry install brings
    // a bundled engine back.
    func canRemoveRejectedPlugin(_ plugin: RejectedPlugin) -> Bool {
        let bundle = plugin.url.standardizedFileURL
        guard !bundle.lastPathComponent.isEmpty, bundle.lastPathComponent != "/" else { return false }
        // The folder, not the bundle, is resolved: a bundle linked in from a build folder is still the user's to remove.
        let folder = bundle.deletingLastPathComponent().resolvingSymlinksInPath().path
        return folder == userPluginsDir.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // To the Trash rather than deleted, so a mistaken removal can be put back.
    func removeRejectedPlugin(
        _ plugin: RejectedPlugin,
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        guard canRemoveRejectedPlugin(plugin) else { throw PluginError.cannotUninstallBuiltIn }
        if FileManager.default.fileExists(atPath: plugin.url.path) {
            do {
                try moveToTrash(plugin.url)
            } catch CocoaError.fileNoSuchFile {}
        }
        removeFromRejected(url: plugin.url)
        Self.logger.info("Moved rejected plugin '\(plugin.name, privacy: .public)' to the Trash")
    }
}
