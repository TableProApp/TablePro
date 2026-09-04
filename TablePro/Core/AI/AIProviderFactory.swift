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
            let provider: ChatTransport
            if let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue) {
                provider = descriptor.makeProvider(config, apiKey)
            } else {
                provider = OpenAICompatibleProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey,
                    providerType: config.type,
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens
                )
            }
            cache[config.id] = (config, apiKey, provider)
            return provider
        }
    }

    static func invalidateCache() {
        cacheLock.withLock { $0.removeAll() }
    }

    static func invalidateCache(for configID: UUID) {
        cacheLock.withLock { $0.removeValue(forKey: configID) }
    }

    /// Resets one session's Copilot conversation on one provider configuration.
    ///
    /// Both scopes are needed. The unscoped form walked the whole cache, so one session starting a
    /// new conversation threw away the server-side conversation id of every other session on every
    /// other provider; naming the configuration alone still reset whichever session's conversation
    /// the shared provider happened to be holding, because there was only one.
    static func resetCopilotConversation(configId: UUID, sessionId: UUID?) {
        cacheLock.withLock { cache in
            guard let copilot = cache[configId]?.provider as? CopilotChatProvider else { return }
            copilot.resetConversation(sessionId: sessionId)
        }
    }

    static func copilotDeleteLastTurn(configId: UUID, sessionId: UUID?) {
        cacheLock.withLock { cache in
            guard let copilot = cache[configId]?.provider as? CopilotChatProvider else { return }
            copilot.deleteLastTurn(sessionId: sessionId)
        }
    }

    /// Which configuration a session streams on. An override that names no live provider falls back
    /// to the active one, so anything keyed by "the configuration this session uses" has to ask here
    /// rather than recompute the choice, or the two answers diverge the moment a provider is deleted.
    static func resolveConfig(
        settings: AISettings,
        overrideProviderId: UUID? = nil
    ) -> AIProviderConfig? {
        if let overrideProviderId,
           let match = settings.providers.first(where: { $0.id == overrideProviderId }) {
            return match
        }
        return settings.activeProvider
    }

    static func resolve(
        settings: AISettings,
        overrideProviderId: UUID? = nil,
        overrideModel: String? = nil
    ) -> ResolvedProvider? {
        guard settings.enabled else { return nil }
        guard let config = resolveConfig(settings: settings, overrideProviderId: overrideProviderId) else {
            return nil
        }
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
