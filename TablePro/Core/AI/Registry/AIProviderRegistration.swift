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
            capabilities: [.reasoning, .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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
                    reasoningEffort: config.reasoningEffort,
                    providerID: config.id
                )
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.claudeAgent.rawValue,
            capabilities: [],
            curatedModels: ClaudeAgent.curatedModels,
            makeProvider: { config, _ in
                ClaudeAgentProvider(model: config.model)
            }
        ))

        /// Gemini has no `.reasoning`: its transport sends no thinking configuration, so an effort
        /// picker there would change nothing.
        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.gemini.rawValue,
            capabilities: [.images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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
            capabilities: [.reasoning, .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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
            capabilities: [.reasoning, .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
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

        for type in AIProviderType.openAICompatibleFamily {
            registry.register(AIProviderDescriptor(
                typeID: type.rawValue,
                capabilities: openAICompatibleCapabilities(for: type),
                makeProvider: { config, apiKey in
                    OpenAICompatibleProvider(config: config, apiKey: apiKey)
                }
            ))
        }

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.copilot.rawValue,
            capabilities: [.modelListFetchable],
            showsTelemetryToggle: true,
            defaultTelemetryEnabled: true,
            oauthFlowKind: .deviceCode,
            makeProvider: { _, _ in CopilotChatProvider() }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.chatgptCodex.rawValue,
            capabilities: [.reasoning],
            curatedModels: chatGPTCodexCuratedModels,
            oauthFlowKind: .browserRedirect,
            makeProvider: { config, _ in
                ChatGPTCodexProvider(model: config.model)
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.cursor.rawValue,
            capabilities: [.modelListFetchable],
            curatedModels: cursorCuratedModels,
            makeProvider: { config, apiKey in
                if let apiKey, !apiKey.isEmpty {
                    return CursorProvider(apiKey: apiKey, model: config.model)
                }
                return CursorAgentProvider(model: config.model)
            }
        ))
    }

    /// Reasoning and images are an envelope here, narrowed per model by what the server's own
    /// model list says. Ollama is the exception: its native route takes `think`, not the
    /// `reasoning_effort` this transport sends.
    private static func openAICompatibleCapabilities(for type: AIProviderType) -> AIProviderCapabilities {
        var capabilities: AIProviderCapabilities = [
            .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable
        ]
        if type != .ollama {
            capabilities.insert(.reasoning)
        }
        if type == .custom {
            capabilities.insert(.nameConfigurable)
        }
        return capabilities
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
}
