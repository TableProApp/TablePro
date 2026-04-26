//
//  AIProviderFactoryResolveTests.swift
//  TableProTests
//
//  Verifies AIProviderFactory.resolve(settings:) returns the active
//  provider's config or nil according to enabled / activeProvider rules.
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIProviderFactory.resolve")
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
        AIProviderFactory.invalidateCache(for: provider.id)
    }

    @Test("Returns ResolvedProvider for an oauth provider (Copilot, no key lookup)")
    func resolvesOauthProvider() {
        let provider = makeProvider(type: .copilot, model: "gpt-4o")
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved != nil)
        #expect(resolved?.config.type == .copilot)
        #expect(resolved?.model == "gpt-4o")
        AIProviderFactory.invalidateCache(for: provider.id)
    }

    @Test("Returns ResolvedProvider for an Ollama provider (no auth)")
    func resolvesOllamaProvider() {
        let provider = makeProvider(type: .ollama, model: "llama3")
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved != nil)
        #expect(resolved?.config.type == .ollama)
        #expect(resolved?.model == "llama3")
        AIProviderFactory.invalidateCache(for: provider.id)
    }

    @Test("Resolves the active provider when multiple are configured")
    func picksActiveAmongMany() {
        let claude = makeProvider(name: "Claude", type: .claude, model: "claude-x")
        let openAI = makeProvider(name: "OpenAI", type: .openAI, model: "gpt-x")
        let target = makeProvider(name: "Gemini", type: .gemini, model: "gemini-x")
        let settings = AISettings(
            enabled: true,
            providers: [claude, openAI, target],
            activeProviderID: target.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved?.config.id == target.id)
        #expect(resolved?.config.type == .gemini)
        AIProviderFactory.invalidateCache(for: claude.id)
        AIProviderFactory.invalidateCache(for: openAI.id)
        AIProviderFactory.invalidateCache(for: target.id)
    }

    @Test("Empty model string passes through to ResolvedProvider")
    func emptyModelPassesThrough() {
        let provider = makeProvider(type: .claude, model: "")
        let settings = AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id
        )
        let resolved = AIProviderFactory.resolve(settings: settings)
        #expect(resolved?.model == "")
        AIProviderFactory.invalidateCache(for: provider.id)
    }
}
