//
//  AIProviderLiveModelInfoTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// These build each transport the way the app does, through the registry, so they fail if the
/// configuration id stops reaching the catalog lookup. Each test owns a fresh id in the shared
/// catalog and removes it afterwards.
struct AIProviderLiveModelInfoTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private let turns = [ChatTurnWire(role: .user, blocks: [.text("hi")])]

    @Test("A router transport built by the app withholds the effort from a model its list marks non-reasoning")
    func registryBuiltRouterReadsTheCatalog() throws {
        var config = AIProviderConfig(preset: .requesty)
        config.model = "alibaba/qwen-max"
        AIModelCatalog.shared.store(providerID: config.id, models: [
            AIModelInfo(id: "alibaba/qwen-max", reasoning: .unsupported),
            AIModelInfo(id: "openai/gpt-5.5", reasoning: AIReasoningSupport(mode: .effortOnly, effortLevels: [.high]))
        ])
        defer { AIModelCatalog.shared.remove(providerID: config.id) }

        let descriptor = try #require(AIProviderRegistry.shared.descriptor(for: config.type.rawValue))
        let transport = try #require(descriptor.makeProvider(config, "key") as? OpenAICompatibleProvider)

        let withheld = try transport.buildChatCompletionRequest(
            turns: turns,
            options: ChatTransportOptions(model: "alibaba/qwen-max", reasoningEffort: .high)
        )
        #expect(try body(of: withheld)["reasoning_effort"] == nil)

        let sent = try transport.buildChatCompletionRequest(
            turns: turns,
            options: ChatTransportOptions(model: "openai/gpt-5.5", reasoningEffort: .high)
        )
        #expect(try body(of: sent)["reasoning_effort"] as? String == "high")
    }

    /// Haiku 4.5 is budgeted in the offline table, so adaptive thinking here can only come from the
    /// list stored under this configuration.
    @Test("A Claude transport built by the app reads reasoning from its own model list")
    func registryBuiltClaudeReadsTheCatalog() throws {
        let config = AIProviderConfig(type: .claude, model: "claude-haiku-4-5")
        AIModelCatalog.shared.store(providerID: config.id, models: [
            AIModelInfo(
                id: "claude-haiku-4-5",
                reasoning: AIReasoningSupport(mode: .adaptive, effortLevels: [.low, .medium, .high])
            )
        ])
        defer { AIModelCatalog.shared.remove(providerID: config.id) }

        let descriptor = try #require(AIProviderRegistry.shared.descriptor(for: config.type.rawValue))
        let transport = try #require(descriptor.makeProvider(config, "key") as? AnthropicProvider)
        let request = try transport.buildMessagesRequest(
            turns: turns,
            options: ChatTransportOptions(model: "claude-haiku-4-5"),
            effort: .high
        )
        let thinking = try #require(try body(of: request)["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
    }
}
