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
            switch config.type {
            case .claude:
                provider = AnthropicProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey ?? ""
                )
            case .gemini:
                provider = GeminiProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey ?? ""
                )
            case .openAI, .openRouter, .ollama, .custom:
                provider = OpenAICompatibleProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey,
                    providerType: config.type
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

    static func resolveProvider(
        for feature: AIFeature,
        settings: AISettings
    ) -> (AIProviderConfig, String?)? {
        if let route = settings.featureRouting[feature.rawValue],
           let config = settings.providers.first(where: { $0.id == route.providerID && $0.isEnabled }) {
            let apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
            return (config, apiKey)
        }

        guard let config = settings.providers.first(where: { $0.isEnabled }) else {
            return nil
        }

        let apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
        return (config, apiKey)
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
