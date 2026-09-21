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
            return OpenAICompatibleProvider(
                endpoint: config.endpoint,
                apiKey: apiKey,
                providerType: config.type,
                model: config.model,
                maxOutputTokens: config.maxOutputTokens
            )
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

    static func resolve(
        settings: AISettings,
        overrideProviderId: UUID? = nil,
        overrideModel: String? = nil
    ) -> ResolvedProvider? {
        guard settings.enabled else { return nil }
        let config: AIProviderConfig?
        if let overrideProviderId,
           let match = settings.providers.first(where: { $0.id == overrideProviderId }) {
            config = match
        } else {
            config = settings.activeProvider
        }
        guard let config else { return nil }
        let apiKey: String?
        switch config.type.authStyle {
        case .apiKey, .optionalApiKey:
            apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
        case .oauth, .none:
            apiKey = nil
        }
        let provider = createProvider(for: config, apiKey: apiKey)
        let model = overrideModel ?? config.model
        return ResolvedProvider(provider: provider, model: model, config: config)
    }
}
