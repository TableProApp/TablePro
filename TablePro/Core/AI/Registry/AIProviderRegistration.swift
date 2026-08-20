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
            effortLevelResolver: { AnthropicModelCapabilities.effortLevels(forModel: $0) },
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
            typeID: AIProviderType.claudeAgent.rawValue,
            displayName: AIProviderType.claudeAgent.displayName,
            defaultEndpoint: "",
            capabilities: [.chat, .models],
            symbolName: AIProviderType.claudeAgent.symbolName,
            curatedModels: ClaudeAgent.curatedModels,
            makeProvider: { config, _ in
                ClaudeAgentProvider(model: config.model)
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.gemini.rawValue,
            displayName: "Gemini",
            defaultEndpoint: "https://generativelanguage.googleapis.com",
            capabilities: [
                .chat, .models, .reasoning, .images,
                .endpointConfigurable, .maxOutputTokens, .modelListFetchable
            ],
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
                .chat, .models, .reasoning, .images,
                .endpointConfigurable, .maxOutputTokens, .modelListFetchable
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

    private static func curatedModel(
        id: String,
        displayName: String,
        provider: AIProviderType,
        defaultEffort: ReasoningEffort? = .medium
    ) -> CuratedModel {
        let reasoning = AIModelOverlay.reasoning(providerTypeID: provider.rawValue, modelID: id)
        return CuratedModel(
            id: id,
            displayName: displayName,
            supportedEffortLevels: reasoning?.effortLevels ?? [],
            defaultEffort: reasoning?.effortLevels.isEmpty == false ? defaultEffort : nil
        )
    }

    private static let chatGPTCodexCuratedModels: [CuratedModel] = ChatGPTCodex.curatedModels.map {
        curatedModel(id: $0.id, displayName: $0.name, provider: .chatgptCodex)
    }

    private static let openAICuratedModels: [CuratedModel] = [
        curatedModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", provider: .openAI),
        curatedModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", provider: .openAI),
        curatedModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", provider: .openAI),
        curatedModel(id: "gpt-5.5", displayName: "GPT-5.5", provider: .openAI)
    ]

    private static let claudeCuratedModels: [CuratedModel] = [
        curatedModel(id: "claude-opus-5", displayName: "Claude Opus 5", provider: .claude),
        curatedModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", provider: .claude),
        curatedModel(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: .claude, defaultEffort: .low)
    ]

    private static func iconForType(_ type: AIProviderType) -> String {
        type.symbolName
    }
}
