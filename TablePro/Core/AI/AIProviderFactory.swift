//
//  AIProviderFactory.swift
//  TablePro
//
//  Factory for creating AI provider instances based on configuration.
//

import Foundation

/// Factory for creating AI provider instances
enum AIProviderFactory {
    /// Create an AI provider for the given configuration
    static func createProvider(
        for config: AIProviderConfig,
        apiKey: String?
    ) -> AIProvider {
        switch config.type {
        case .claude:
            return AnthropicProvider(
                endpoint: config.endpoint,
                apiKey: apiKey ?? ""
            )
        case .gemini:
            return GeminiProvider(
                endpoint: config.endpoint,
                apiKey: apiKey ?? ""
            )
        case .openAI, .openRouter, .ollama, .custom:
            return OpenAICompatibleProvider(
                endpoint: config.endpoint,
                apiKey: apiKey,
                providerType: config.type
            )
        }
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
}
