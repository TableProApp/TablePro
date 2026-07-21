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
            capabilities: [.chat, .models, .reasoning, .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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
            capabilities: [.chat, .models, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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
            capabilities: [.chat, .models, .reasoning, .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.xai.rawValue,
            displayName: AIProviderType.xai.displayName,
            defaultEndpoint: AIProviderType.xai.defaultEndpoint,
            capabilities: [
                .chat, .models, .reasoning, .images,
                .endpointConfigurable, .maxOutputTokens, .modelListFetchable
            ],
            symbolName: iconForType(.xai),
            curatedModels: XAI.apiCuratedModels,
            makeProvider: { config, apiKey in
                if let apiKey, !apiKey.isEmpty {
                    return OpenAIResponsesProvider(
                        endpoint: config.endpoint,
                        apiKey: apiKey,
                        model: config.model,
                        maxOutputTokens: config.maxOutputTokens,
                        dialect: .xai
                    )
                }
                return XAIGrokProvider(model: config.model)
            }
        ))

        for type in [AIProviderType.openRouter, .openCode, .ollama, .llamaCpp, .mlx, .custom] {
            var capabilities: AIProviderCapabilities = [
                .chat, .models, .endpointConfigurable, .maxOutputTokens, .modelListFetchable
            ]
            if type == .custom {
                capabilities.insert(.nameConfigurable)
            }
            registry.register(AIProviderDescriptor(
                typeID: type.rawValue,
                displayName: type.displayName,
                defaultEndpoint: type.defaultEndpoint,
                capabilities: capabilities,
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
            capabilities: [.chat, .models, .modelListFetchable],
            symbolName: AIProviderType.copilot.symbolName,
            showsTelemetryToggle: true,
            defaultTelemetryEnabled: true,
            oauthFlowKind: .deviceCode,
            makeProvider: { _, _ in CopilotChatProvider() }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.chatgptCodex.rawValue,
            displayName: AIProviderType.chatgptCodex.displayName,
            defaultEndpoint: "",
            capabilities: [.chat, .inline, .models, .reasoning],
            symbolName: AIProviderType.chatgptCodex.symbolName,
            curatedModels: chatGPTCodexCuratedModels,
            oauthFlowKind: .browserRedirect,
            makeProvider: { config, _ in
                ChatGPTCodexProvider(model: config.model)
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.cursor.rawValue,
            displayName: AIProviderType.cursor.displayName,
            defaultEndpoint: "",
            capabilities: [.chat, .inline, .models, .modelListFetchable],
            symbolName: AIProviderType.cursor.symbolName,
            curatedModels: cursorCuratedModels,
            makeProvider: { config, apiKey in
                if let apiKey, !apiKey.isEmpty {
                    return CursorProvider(apiKey: apiKey, model: config.model)
                }
                return CursorAgentProvider(model: config.model)
            }
        ))
    }

    private static let cursorCuratedModels: [CuratedModel] = CursorAI.curatedModels.map {
        CuratedModel(id: $0.id, displayName: $0.name)
    }

    private static let chatGPTCodexCuratedModels: [CuratedModel] = [
        CuratedModel(
            id: "gpt-5.5",
            displayName: "GPT-5.5",
            supportedEffortLevels: ReasoningEffort.allCases,
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            supportedEffortLevels: [.low, .medium, .high],
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            supportedEffortLevels: ReasoningEffort.allCases,
            defaultEffort: .medium
        )
    ]

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
