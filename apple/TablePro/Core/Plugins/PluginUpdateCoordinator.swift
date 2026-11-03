import Foundation

extension PluginManager {
    func performRegistryUpdate(_ registryPlugin: RegistryPlugin) async -> PluginActionResult {
        do {
            switch try await updateFromRegistry(registryPlugin, trigger: .user) {
            case .installed(let entry):
                return .succeeded(entry: entry)
            case .staged:
                return .staged
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error: error)
        }
    }
}

enum PluginActionResult: Sendable {
    case succeeded(entry: PluginEntry)
    case staged
    case cancelled
    case failed(error: any Error)
}
