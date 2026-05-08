//
//  AIProviderRegistration.swift
//  TablePro
//
//  Registers all built-in AI provider descriptors at app launch.
//

import Foundation

enum AIProviderRegistration {
    static func registerAll() {
        let registry = AIProviderRegistry.shared

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.claude.rawValue,
            displayName: "Claude",
            defaultEndpoint: "https://api.anthropic.com",
            requiresAPIKey: true,
            capabilities: [.chat, .models],
            symbolName: "brain",
            makeProvider: { config, apiKey in
                AnthropicProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey ?? "",
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens ?? 4_096
                )
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.gemini.rawValue,
            displayName: "Gemini",
            defaultEndpoint: "https://generativelanguage.googleapis.com",
            requiresAPIKey: true,
            capabilities: [.chat, .models],
            symbolName: "wand.and.stars",
            makeProvider: { config, apiKey in
                GeminiProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey ?? "",
                    maxOutputTokens: config.maxOutputTokens ?? 8_192
                )
            }
        ))

        // OpenAI, OpenRouter, Ollama, Custom all use OpenAICompatibleProvider
        for type in [AIProviderType.openAI, .openRouter, .ollama, .custom] {
            registry.register(AIProviderDescriptor(
                typeID: type.rawValue,
                displayName: type.displayName,
                defaultEndpoint: type.defaultEndpoint,
                requiresAPIKey: type.authStyle == .apiKey,
                capabilities: [.chat, .models],
                symbolName: iconForType(type),
                makeProvider: { config, apiKey in
                    OpenAICompatibleProvider(
                        endpoint: config.endpoint,
                        apiKey: apiKey,
                        providerType: config.type,
                        model: config.model,
                        maxOutputTokens: config.maxOutputTokens
                    )
                }
            ))
        }

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.copilot.rawValue,
            displayName: "GitHub Copilot",
            defaultEndpoint: "",
            requiresAPIKey: false,
            capabilities: [.chat, .models],
            symbolName: AIProviderType.copilot.symbolName,
            makeProvider: { _, _ in CopilotChatProvider() }
        ))
    }

    private static func iconForType(_ type: AIProviderType) -> String {
        switch type {
        case .openAI: return "cpu"
        case .openRouter: return "globe"
        case .ollama: return "desktopcomputer"
        case .custom: return "server.rack"
        default: return "questionmark.circle"
        }
    }
}
