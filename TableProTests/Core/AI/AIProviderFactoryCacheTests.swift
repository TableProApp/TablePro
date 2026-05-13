//
//  AIProviderFactoryCacheTests.swift
//  TableProTests
//
//  Verifies AIProviderFactory.createProvider returns a fresh instance
//  whenever any field of AIProviderConfig changes — not only id/apiKey.
//  Regression coverage for the bug where mid-edit endpoint changes were
//  ignored because the cache key was just (id, apiKey).
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AIProviderFactory cache")
@MainActor
struct AIProviderFactoryCacheTests {
    private func makeConfig(
        id: UUID,
        type: AIProviderType = .openAI,
        name: String = "Test",
        model: String = "gpt-x",
        endpoint: String = "https://api.openai.com",
        maxOutputTokens: Int? = nil
    ) -> AIProviderConfig {
        AIProviderConfig(
            id: id,
            name: name,
            type: type,
            model: model,
            endpoint: endpoint,
            maxOutputTokens: maxOutputTokens
        )
    }

    // MARK: - Cache hit

    @Test("Identical config + apiKey returns the same cached instance")
    func cacheHitReturnsSameInstance() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let config = makeConfig(id: id)
        let first = AIProviderFactory.createProvider(for: config, apiKey: "k")
        let second = AIProviderFactory.createProvider(for: config, apiKey: "k")
        #expect(first === second)
    }

    // MARK: - Cache miss on config changes (the bug)

    @Test("Endpoint change rebuilds the provider (the regression)")
    func endpointChangeBypassesCache() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let original = makeConfig(id: id, endpoint: "https://api.openai.com")
        let mutated = makeConfig(id: id, endpoint: "https://api.deepseek.com")
        let first = AIProviderFactory.createProvider(for: original, apiKey: "k")
        let second = AIProviderFactory.createProvider(for: mutated, apiKey: "k")
        #expect(first !== second)
    }

    @Test("Model change rebuilds the provider")
    func modelChangeBypassesCache() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let original = makeConfig(id: id, model: "gpt-4")
        let mutated = makeConfig(id: id, model: "gpt-4o")
        let first = AIProviderFactory.createProvider(for: original, apiKey: "k")
        let second = AIProviderFactory.createProvider(for: mutated, apiKey: "k")
        #expect(first !== second)
    }

    @Test("maxOutputTokens change rebuilds the provider")
    func maxOutputTokensChangeBypassesCache() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let original = makeConfig(id: id, maxOutputTokens: nil)
        let mutated = makeConfig(id: id, maxOutputTokens: 2_048)
        let first = AIProviderFactory.createProvider(for: original, apiKey: "k")
        let second = AIProviderFactory.createProvider(for: mutated, apiKey: "k")
        #expect(first !== second)
    }

    @Test("Name change rebuilds the provider (full-config equality)")
    func nameChangeBypassesCache() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let original = makeConfig(id: id, name: "A")
        let mutated = makeConfig(id: id, name: "B")
        let first = AIProviderFactory.createProvider(for: original, apiKey: "k")
        let second = AIProviderFactory.createProvider(for: mutated, apiKey: "k")
        #expect(first !== second)
    }

    @Test("apiKey change rebuilds the provider")
    func apiKeyChangeBypassesCache() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let config = makeConfig(id: id)
        let first = AIProviderFactory.createProvider(for: config, apiKey: "old")
        let second = AIProviderFactory.createProvider(for: config, apiKey: "new")
        #expect(first !== second)
    }

    @Test("nil → non-nil apiKey transition rebuilds the provider")
    func apiKeyNilToValueRebuilds() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let config = makeConfig(id: id)
        let first = AIProviderFactory.createProvider(for: config, apiKey: nil)
        let second = AIProviderFactory.createProvider(for: config, apiKey: "k")
        #expect(first !== second)
    }

    // MARK: - Mid-edit scenario

    @Test("Stale cached provider after empty-endpoint debounce is replaced when endpoint is finalized")
    func midEditEndpointBecomesActive() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        // Mimic the SwiftUI flow: scheduleFetchModels fires while user is mid-typing
        // with an empty/partial endpoint, then again once the field is filled in.
        let mid = makeConfig(id: id, endpoint: "")
        let final = makeConfig(id: id, endpoint: "https://api.deepseek.com")
        let staleProvider = AIProviderFactory.createProvider(for: mid, apiKey: "k")
        let liveProvider = AIProviderFactory.createProvider(for: final, apiKey: "k")
        #expect(staleProvider !== liveProvider)
    }

    // MARK: - Cache isolation by id

    @Test("Different provider ids never share cached instances")
    func differentIdsAreIndependent() {
        let firstID = UUID()
        let secondID = UUID()
        defer {
            AIProviderFactory.invalidateCache(for: firstID)
            AIProviderFactory.invalidateCache(for: secondID)
        }
        let firstConfig = makeConfig(id: firstID)
        let secondConfig = makeConfig(id: secondID)
        let first = AIProviderFactory.createProvider(for: firstConfig, apiKey: "k")
        let second = AIProviderFactory.createProvider(for: secondConfig, apiKey: "k")
        #expect(first !== second)
    }

    // MARK: - Invalidation

    @Test("invalidateCache(for:) forces the next call to rebuild")
    func invalidateForIdRebuilds() {
        let id = UUID()
        defer { AIProviderFactory.invalidateCache(for: id) }
        let config = makeConfig(id: id)
        let first = AIProviderFactory.createProvider(for: config, apiKey: "k")
        AIProviderFactory.invalidateCache(for: id)
        let second = AIProviderFactory.createProvider(for: config, apiKey: "k")
        #expect(first !== second)
    }

    @Test("invalidateCache(for:) only affects the targeted id")
    func invalidateForIdLeavesOthersIntact() {
        let targetID = UUID()
        let bystanderID = UUID()
        defer {
            AIProviderFactory.invalidateCache(for: targetID)
            AIProviderFactory.invalidateCache(for: bystanderID)
        }
        let target = makeConfig(id: targetID)
        let bystander = makeConfig(id: bystanderID)
        _ = AIProviderFactory.createProvider(for: target, apiKey: "k")
        let bystanderFirst = AIProviderFactory.createProvider(for: bystander, apiKey: "k")
        AIProviderFactory.invalidateCache(for: targetID)
        let bystanderSecond = AIProviderFactory.createProvider(for: bystander, apiKey: "k")
        #expect(bystanderFirst === bystanderSecond)
    }
}
