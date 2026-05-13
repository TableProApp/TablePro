//
//  AIProviderRegistration.swift
//  TablePro
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
            capabilities: [.chat, .models, .reasoning, .images],
            symbolName: "brain",
            curatedModels: claudeCuratedModels,
            makeProvider: { config, apiKey in
                AnthropicProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey ?? "",
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens
                        ?? config.reasoningEffort?.autoScaledMaxOutputTokens
                        ?? 4_096,
                    reasoningEffort: config.reasoningEffort
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

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.openAI.rawValue,
            displayName: AIProviderType.openAI.displayName,
            defaultEndpoint: AIProviderType.openAI.defaultEndpoint,
            requiresAPIKey: true,
            capabilities: [.chat, .models, .reasoning, .images],
            symbolName: iconForType(.openAI),
            curatedModels: openAICuratedModels,
            makeProvider: { config, apiKey in
                OpenAIResponsesProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey,
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens
                )
            }
        ))

        for type in [AIProviderType.openRouter, .ollama, .custom] {
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

    private static let openAICuratedModels: [CuratedModel] = [
        CuratedModel(
            id: "gpt-5.5",
            displayName: "GPT-5.5",
            supportedEffortLevels: ReasoningEffort.allCases,
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "gpt-5-codex",
            displayName: "GPT-5 Codex",
            supportedEffortLevels: [.low, .medium, .high],
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "gpt-5.3-codex",
            displayName: "GPT-5.3 Codex",
            supportedEffortLevels: [.low, .medium, .high, .xhigh],
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            supportedEffortLevels: ReasoningEffort.allCases,
            defaultEffort: .medium
        )
    ]

    private static let claudeCuratedModels: [CuratedModel] = [
        CuratedModel(
            id: "claude-opus-4-7-20260101",
            displayName: "Claude Opus 4.7",
            supportedEffortLevels: [.low, .medium, .high, .xhigh],
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "claude-sonnet-4-6-20251101",
            displayName: "Claude Sonnet 4.6",
            supportedEffortLevels: [.low, .medium, .high, .xhigh],
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "claude-haiku-4-5-20251001",
            displayName: "Claude Haiku 4.5",
            supportedEffortLevels: [.low, .medium, .high],
            defaultEffort: .low
        )
    ]

    private static func iconForType(_ type: AIProviderType) -> String {
        type.symbolName
    }
}
