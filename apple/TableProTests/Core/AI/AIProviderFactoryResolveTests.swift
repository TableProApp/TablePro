//
//  AIProviderFactoryResolveTests.swift
//  TableProTests
//
//  Verifies AIProviderFactory.resolve(settings:) returns the active
//  provider's config or nil according to enabled / activeProvider rules.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct AIProviderFactoryResolveTests {
    /// Each test uses a unique provider id so the factory cache (keyed by id)
    /// doesn't leak state between tests.
    private func makeProvider(
        id: UUID = UUID(),
        name: String = "Test",
        type: AIProviderType = .claude,
        model: String = "test-model"
    ) -> AIProviderConfig {
        AIProviderConfig(id: id, name: name, type: type, model: model)
    }

    @Test("Returns nil when AI is disabled")
    func nilWhenDisabled() {
        let provider = makeProvider()
        let settings = AISettings(
            enabled: false,
            providers: [provider],
            activeProviderID: provider.id
        )
        #expect(AIProviderFactory.resolve(settings: settings) == nil)
    }

    @Test("Returns nil when no active provider is set")
    func nilWhenNoActive() {
        let provider = makeProvider()
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: nil
        )
        #expect(AIProviderFactory.resolve(settings: settings) == nil)
    }

    @Test("Returns nil when activeProviderID points to a missing provider")
    func nilWhenIDDoesNotMatch() {
        let provider = makeProvider()
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: UUID()
        )
        #expect(AIProviderFactory.resolve(settings: settings) == nil)
    }

    @Test("Returns ResolvedProvider for an active apiKey provider")
    func resolvesApiKeyProvider() {
        let provider = makeProvider(type: .claude, model: "claude-3-5-sonnet")
        defer { AIProviderFactory.invalidateCache(for: provider.id) }
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved != nil)
        #expect(resolved?.config.id == provider.id)
        #expect(resolved?.config.type == .claude)
        #expect(resolved?.model == "claude-3-5-sonnet")
    }

    @Test("Returns ResolvedProvider for an oauth provider (Copilot, no key lookup)")
    func resolvesOauthProvider() {
        let provider = makeProvider(type: .copilot, model: "gpt-4o")
        defer { AIProviderFactory.invalidateCache(for: provider.id) }
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved != nil)
        #expect(resolved?.config.type == .copilot)
        #expect(resolved?.model == "gpt-4o")
    }

    @Test("Returns ResolvedProvider for an Ollama provider (no auth)")
    func resolvesOllamaProvider() {
        let provider = makeProvider(type: .ollama, model: "llama3")
        defer { AIProviderFactory.invalidateCache(for: provider.id) }
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved != nil)
        #expect(resolved?.config.type == .ollama)
        #expect(resolved?.model == "llama3")
    }

    @Test("Resolves the active provider when multiple are configured")
    func picksActiveAmongMany() {
        let claude = makeProvider(name: "Claude", type: .claude, model: "claude-x")
        let openAI = makeProvider(name: "OpenAI", type: .openAI, model: "gpt-x")
        let target = makeProvider(name: "Gemini", type: .gemini, model: "gemini-x")
        defer { AIProviderFactory.invalidateCache(for: target.id) }
        let settings = AISettings(
            enabled: true,
            providers: [claude, openAI, target],
            activeProviderID: target.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved?.config.id == target.id)
        #expect(resolved?.config.type == .gemini)
    }

    @Test("Returns a ChatGPTCodexProvider for an active ChatGPT oauth provider")
    func resolvesChatGPTCodexProvider() {
        AIProviderRegistration.registerAll()
        let provider = makeProvider(type: .chatgptCodex, model: "gpt-5.5")
        defer { AIProviderFactory.invalidateCache(for: provider.id) }
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved != nil)
        #expect(resolved?.config.type == .chatgptCodex)
        #expect(resolved?.provider is ChatGPTCodexProvider)
    }

    @Test("Empty model string passes through to ResolvedProvider")
    func emptyModelPassesThrough() {
        let provider = makeProvider(type: .claude, model: "")
        defer { AIProviderFactory.invalidateCache(for: provider.id) }
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved?.model == "")
    }

    /// The chat panel keeps its pick after the picked provider is removed in Settings, and the
    /// next turn went to the active provider under the removed provider's model id.
    @Test("A model picked for a removed provider is not sent to the active one")
    func removedOverrideProviderDropsItsModel() {
        let active = makeProvider(model: "claude-sonnet-5")
        let settings = AISettings(enabled: true, providers: [active], activeProviderID: active.id)
        let resolved = AIProviderFactory.resolve(
            settings: settings,
            overrideProviderId: UUID(),
            overrideModel: "muse-spark-1.3"
        )
        #expect(resolved?.config.id == active.id)
        #expect(resolved?.model == "claude-sonnet-5")
    }

    @Test("A model picked for a provider that still exists is sent to it")
    func overrideModelGoesToItsProvider() {
        let active = makeProvider(model: "claude-sonnet-5")
        let other = makeProvider(type: .custom, model: "muse-spark-1.3")
        let settings = AISettings(enabled: true, providers: [active, other], activeProviderID: active.id)
        let resolved = AIProviderFactory.resolve(
            settings: settings,
            overrideProviderId: other.id,
            overrideModel: "muse-wonder-1.0"
        )
        #expect(resolved?.config.id == other.id)
        #expect(resolved?.model == "muse-wonder-1.0")
    }
}
