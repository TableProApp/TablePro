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
                return .staged
            }
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
