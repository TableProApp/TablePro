//
//  AIProviderFactory.swift
//  TablePro
//

import Foundation
import os

enum AIProviderFactory {
    struct ResolvedProvider: Sendable {
        let provider: ChatTransport
        let model: String
        let config: AIProviderConfig
    }

    private static let cacheLock = OSAllocatedUnfairLock(
        initialState: [UUID: (config: AIProviderConfig, apiKey: String?, provider: ChatTransport)]()
    )

    static func createProvider(for config: AIProviderConfig, apiKey: String?) -> ChatTransport {
        cacheLock.withLock { cache in
            if let cached = cache[config.id], cached.apiKey == apiKey, cached.config == config {
                return cached.provider
            }
            let provider = makeUncachedProvider(for: config, apiKey: apiKey)
            cache[config.id] = (config, apiKey, provider)
            return provider
        }
    }

    /// A transport built outside the per-id cache, for testing a configuration that is still being
    /// edited. The Settings sheet works on a copy of a saved provider under the same id, so caching
    /// a half-typed endpoint would hand it to the session already streaming through that provider.
    static func makeUncachedProvider(for config: AIProviderConfig, apiKey: String?) -> ChatTransport {
        guard let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue) else {
            return OpenAICompatibleProvider(config: config, apiKey: apiKey)
        }
        return descriptor.makeProvider(config, apiKey)
    }

    static func invalidateCache() {
        cacheLock.withLock { $0.removeAll() }
    }

    static func invalidateCache(for configID: UUID) {
        cacheLock.withLock { $0.removeValue(forKey: configID) }
    }

    /// Both of these name a session, because Copilot conversation state is per session even though
    /// the provider is cached per configuration. Without the id, one session starting a new
    /// conversation reset every other session sharing that configuration.
    static func resetCopilotConversation(sessionId: UUID) {
        cacheLock.withLock { cache in
            for (_, entry) in cache {
                if let copilot = entry.provider as? CopilotChatProvider {
                    copilot.resetConversation(sessionId: sessionId)
                }
            }
        }
    }

    static func copilotDeleteLastTurn(sessionId: UUID) {
        cacheLock.withLock { cache in
            for (_, entry) in cache {
                if let copilot = entry.provider as? CopilotChatProvider {
                    copilot.deleteLastTurn(sessionId: sessionId)
                }
            }
        }
    }

    // `onlyWhereRequired` is for inline suggestions: they send an effort only where a model always reasons.
    static func reasoningEffort(
        _ requested: ReasoningEffort?,
        config: AIProviderConfig,
        model: String,
        onlyWhereRequired: Bool = false,
        catalog: AIModelCatalog = .shared
    ) -> ReasoningEffort? {
        guard let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue) else {
            return onlyWhereRequired ? nil : requested
        }
        let fetched = catalog.fetchedInfo(providerID: config.id, modelID: model)
        if onlyWhereRequired,
           !descriptor.reasoning(forModelID: model, fetched: fetched, preset: config.preset).isMandatory {
            return nil
        }
        return descriptor.effort(requested, forModelID: model, fetched: fetched, preset: config.preset)
    }

    static func resolve(
        settings: AISettings,
        overrideProviderId: UUID? = nil,
        overrideModel: String? = nil
    ) -> ResolvedProvider? {
        guard settings.enabled else { return nil }
        let config: AIProviderConfig?
        // A model picked for a provider that was since removed belongs to that provider, not the active one.
        var model = overrideModel
        if let overrideProviderId,
           let match = settings.providers.first(where: { $0.id == overrideProviderId }) {
            config = match
        } else {
            config = settings.activeProvider
            if overrideProviderId != nil { model = nil }
        }
        guard let config else { return nil }
        let apiKey: String?
        switch config.authStyle {
        case .apiKey, .optionalApiKey:
            apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
        case .oauth, .none:
            apiKey = nil
        }
        let provider = createProvider(for: config, apiKey: apiKey)
        return ResolvedProvider(provider: provider, model: model ?? config.model, config: config)
    }
}
