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
            makeProvider: { config, apiKey in
                AnthropicProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey ?? "",
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens,
                    providerID: config.id
                )
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.claudeAgent.rawValue,
            capabilities: [.modelListFetchable],
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
            makeProvider: { config, apiKey in
                OpenAIResponsesProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey,
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens,
                    providerID: config.id,
                    source: AIModelSource(config: config)
                )
            }
        ))

        registry.register(AIProviderDescriptor(
            typeID: AIProviderType.xai.rawValue,
            capabilities: [.reasoning, .images, .endpointConfigurable, .maxOutputTokens, .modelListFetchable],
            makeProvider: { config, apiKey in
                OpenAIResponsesProvider(
                    endpoint: config.endpoint,
                    apiKey: apiKey,
                    model: config.model,
                    maxOutputTokens: config.maxOutputTokens,
                    dialect: .xai,
                    providerID: config.id,
                    source: AIModelSource(config: config)
                )
            }
        ))

        for type in AIProviderType.openAICompatibleFamily {
            registry.register(AIProviderDescriptor(
                typeID: type.rawValue,
                capabilities: openAICompatibleCapabilities(for: type),
                unknownReasoning: AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high]),
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
            capabilities: [.reasoning, .modelListFetchable],
            oauthFlowKind: .browserRedirect,
            makeProvider: { config, _ in
                ChatGPTCodexProvider(model: config.model)
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
}
