import Combine
import Foundation

struct AIModelListInputs: Equatable {
    let endpoint: String
    let apiKey: String
}

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
    // The key and Base URL the last finished request answered for, with a list or an error.
    @Published private(set) var answeredFor: AIModelListInputs?

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
        let result = await AIModelCatalog.list(for: config, using: transport)
        guard mine == generation else { return }
        isLoading = false
        answeredFor = AIModelListInputs(endpoint: config.endpoint, apiKey: apiKey)
        guard let failure = result.error else {
            models = result.models
            loadedFor = connection
            isCurrent = true
            return
        }
        // A list from another key or Base URL does not describe the server that just failed.
        if loadedFor != connection {
            models = result.models
            isCurrent = false
            loadedFor = nil
        }
        error = failure.localizedDescription
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
