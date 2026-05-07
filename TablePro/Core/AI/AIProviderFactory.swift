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

    static func resetCopilotConversation() {
        cacheLock.withLock { cache in
            for (_, entry) in cache {
                if let copilot = entry.provider as? CopilotChatProvider {
                    copilot.resetConversation()
                }
            }
        }
    }

    static func copilotDeleteLastTurn() {
        cacheLock.withLock { cache in
            for (_, entry) in cache {
                if let copilot = entry.provider as? CopilotChatProvider {
                    copilot.deleteLastTurn()
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
        case .apiKey:
            apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
        case .oauth, .none:
            apiKey = nil
        }
        let provider = createProvider(for: config, apiKey: apiKey)
        let model = overrideModel ?? config.model
        return ResolvedProvider(provider: provider, model: model, config: config)
    }
}
