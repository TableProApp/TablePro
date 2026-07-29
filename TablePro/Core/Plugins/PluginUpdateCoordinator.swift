//
//  PluginUpdateCoordinator.swift
//  TablePro
//

import Foundation

extension PluginManager {
    func performRegistryUpdate(_ registryPlugin: RegistryPlugin) async -> PluginActionResult {
        let tracker = PluginInstallTracker.shared
        tracker.beginInstall(pluginId: registryPlugin.id)
        do {
            let outcome = try await updateFromRegistry(registryPlugin) { fraction in
                tracker.updateProgress(pluginId: registryPlugin.id, fraction: fraction)
                if fraction >= 1.0 {
                    tracker.markInstalling(pluginId: registryPlugin.id)
                }
            }
            switch outcome {
            case .installed(let entry):
                tracker.completeInstall(pluginId: registryPlugin.id)
                return .succeeded(entry: entry)
            case .staged:
                tracker.markStaged(pluginId: registryPlugin.id, newVersion: registryPlugin.version)
                return .staged
            }
        } catch {
            tracker.failInstall(pluginId: registryPlugin.id, error: error.localizedDescription)
            return .failed(error: error)
        }
    }

    func performRegistryInstall(_ registryPlugin: RegistryPlugin) async -> PluginActionResult {
        let tracker = PluginInstallTracker.shared
        tracker.beginInstall(pluginId: registryPlugin.id)
        do {
            let entry = try await installFromRegistry(registryPlugin) { fraction in
                tracker.updateProgress(pluginId: registryPlugin.id, fraction: fraction)
                if fraction >= 1.0 {
                    tracker.markInstalling(pluginId: registryPlugin.id)
                }
            }
            tracker.completeInstall(pluginId: registryPlugin.id)
            return .succeeded(entry: entry)
        } catch {
            tracker.failInstall(pluginId: registryPlugin.id, error: error.localizedDescription)
            return .failed(error: error)
        }
    }
}

enum PluginActionResult: Sendable {
    case succeeded(entry: PluginEntry)
    case staged
    case failed(error: any Error)
}
