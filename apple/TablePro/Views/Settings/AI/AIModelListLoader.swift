import Combine
import Foundation

@MainActor
final class AIModelListLoader: ObservableObject {
    private struct Connection: Equatable {
        let providerID: UUID
        let endpoint: String
        let apiKey: String
    }

    @Published private(set) var models: [AIModelInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var blocker: AIModelListFetchGate.Blocker?
    // True once a list loaded for the key and Base URL of the last request.
    @Published private(set) var isCurrent = false

    private var loadedFor: Connection?
    private var generation = 0

    func load(config: AIProviderConfig, apiKey: String) async {
        generation += 1
        let mine = generation
        let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue)
        let connection = Connection(providerID: config.id, endpoint: config.endpoint, apiKey: apiKey)

        if let blocked = AIProviderDraftRules.modelListBlocker(descriptor: descriptor, draft: config, apiKey: apiKey) {
            blocker = blocked
            models = []
            isCurrent = false
            loadedFor = nil
            error = nil
            isLoading = false
            return
        }

        blocker = nil
        error = nil
        isLoading = true
        let transport = AIProviderFactory.makeUncachedProvider(for: config, apiKey: apiKey)
        do {
            let fetched = try await transport.fetchAvailableModels()
            guard mine == generation else { return }
            models = fetched
            loadedFor = connection
            isCurrent = true
            isLoading = false
        } catch {
            guard mine == generation else { return }
            // A list from another key or Base URL does not describe the server that just failed.
            if loadedFor != connection {
                models = []
                isCurrent = false
                loadedFor = nil
            }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // The draft's key or Base URL changed, so the list on screen no longer answers for it.
    func markStale() {
        isCurrent = false
    }

    func cancel() {
        generation += 1
        isLoading = false
    }
}
