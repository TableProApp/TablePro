//
//  AIProviderFactory.swift
//  TablePro
//
//  Factory for creating AI provider instances based on configuration.
//

import Foundation
import os

/// Factory for creating AI provider instances
enum AIProviderFactory {
    /// Resolved provider ready for use
    struct ResolvedProvider {
        let provider: AIProvider
        let model: String
        let config: AIProviderConfig
    }

    private static let cacheLock = OSAllocatedUnfairLock(
        initialState: [UUID: (apiKey: String?, provider: AIProvider)]()
    )

    /// Create or return a cached AI provider for the given configuration
    static func createProvider(
        for config: AIProviderConfig,
        apiKey: String?
    ) -> AIProvider {
        cacheLock.withLock { cache in
            if let cached = cache[config.id], cached.apiKey == apiKey {
                return cached.provider
            }

            let provider: AIProvider
            if let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue) {
                provider = descriptor.makeProvider(config, apiKey)
            } else {
                provider = OpenAICompatibleProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey,
                    providerType: config.type,
                    maxOutputTokens: config.maxOutputTokens
                )
            }
            cache[config.id] = (apiKey, provider)
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

    static func resolveProvider(
        for feature: AIFeature,
        settings: AISettings
    ) -> (AIProviderConfig, String?)? {
        // Check feature routing: explicit provider or Copilot
        if let route = settings.featureRouting[feature.rawValue] {
            // Routed to Copilot
            if route.providerID == AIProviderConfig.copilotProviderID, settings.copilotChatEnabled {
                let config = AIProviderConfig(
                    id: AIProviderConfig.copilotProviderID,
                    name: "GitHub Copilot",
                    type: .copilot,
                    model: route.model,
                    endpoint: ""
                )
                return (config, nil)
            }

            // Routed to a regular provider
            if let config = settings.providers.first(where: { $0.id == route.providerID && $0.isEnabled }) {
                let apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
                return (config, apiKey)
            }
        }

        // Fallback: first enabled provider
        if let config = settings.providers.first(where: { $0.isEnabled }) {
            let apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
            return (config, apiKey)
        }

        // Last resort: if copilotChatEnabled and no other providers, use Copilot
        if settings.copilotChatEnabled {
            let config = AIProviderConfig(
                id: AIProviderConfig.copilotProviderID,
                name: "GitHub Copilot",
                type: .copilot,
                model: "",
                endpoint: ""
            )
            return (config, nil)
        }

        return nil
    }

    static func resolveModel(
        for feature: AIFeature,
        config: AIProviderConfig,
        settings: AISettings
    ) -> String {
        if let route = settings.featureRouting[feature.rawValue], !route.model.isEmpty {
            return route.model
        }
        return config.model
    }

    /// Resolve provider, model, and config in one step
    static func resolve(for feature: AIFeature, settings: AISettings) -> ResolvedProvider? {
        guard let (config, apiKey) = resolveProvider(for: feature, settings: settings) else {
            return nil
        }
        let model = resolveModel(for: feature, config: config, settings: settings)
        let provider = createProvider(for: config, apiKey: apiKey)
        return ResolvedProvider(provider: provider, model: model, config: config)
    }
}
