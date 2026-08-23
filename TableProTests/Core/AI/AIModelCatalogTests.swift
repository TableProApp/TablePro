//
//  AIModelCatalogTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AI model catalog")
struct AIModelCatalogTests {
    private let claude = AIProviderType.claude.rawValue

    @Test("Live provider metadata wins over the static overlay")
    func liveMetadataWins() {
        let catalog = AIModelCatalog()
        let live = AIModelInfo(
            id: "claude-haiku-4-5",
            displayName: "Claude Haiku 4.5",
            maxOutputTokens: 64_000,
            reasoning: AIReasoningSupport(mode: .adaptive, effortLevels: [.low, .medium, .high, .xhigh])
        )
        catalog.store(providerTypeID: claude, models: [live])

        let resolved = catalog.resolve(providerTypeID: claude, modelID: "claude-haiku-4-5")
        #expect(resolved.reasoning?.mode == .adaptive, "live metadata must override the offline table")
        #expect(resolved.maxOutputTokens == 64_000)
        #expect(resolved.displayName == "Claude Haiku 4.5")
    }

    @Test("Without live metadata the overlay supplies the answer")
    func overlayFallback() {
        let catalog = AIModelCatalog()
        let resolved = catalog.resolve(providerTypeID: claude, modelID: "claude-haiku-4-5")
        #expect(resolved.reasoning?.mode == .budgeted, "Haiku 4.5 has no adaptive thinking")
        #expect(resolved.reasoning?.effortLevels == [.low, .medium, .high])
    }

    @Test("An unknown provider and model still resolve to a usable value")
    func unknownResolvesToPlainInfo() {
        let catalog = AIModelCatalog()
        let resolved = catalog.resolve(providerTypeID: "nonexistent", modelID: "some-model")
        #expect(resolved.id == "some-model")
        #expect(resolved.reasoning == nil)
    }

    @Test("Storing an empty list never erases what is already known")
    func emptyStoreIsIgnored() {
        let catalog = AIModelCatalog()
        let live = AIModelInfo(id: "m", reasoning: AIReasoningSupport(mode: .adaptive, effortLevels: [.high]))
        catalog.store(providerTypeID: claude, models: [live])
        catalog.store(providerTypeID: claude, models: [])
        #expect(catalog.fetchedInfo(providerTypeID: claude, modelID: "m") != nil)
    }

    @Test("Merging fills only the fields the provider left unknown")
    func mergingPrefersLiveFields() {
        let live = AIModelInfo(id: "m", displayName: nil, maxOutputTokens: 100)
        let fallback = AIModelInfo(
            id: "m",
            displayName: "Fallback",
            maxOutputTokens: 999,
            reasoning: AIReasoningSupport(mode: .budgeted, effortLevels: [.low])
        )
        let merged = live.merging(fallback: fallback)
        #expect(merged.maxOutputTokens == 100, "a live value must not be overwritten")
        #expect(merged.displayName == "Fallback", "an unknown live field takes the fallback")
        #expect(merged.reasoning?.mode == .budgeted)
    }

    @Test("Anthropic capability payloads decode into reasoning support")
    func anthropicCapabilityDecoding() throws {
        let adaptive: [String: Any] = [
            "id": "claude-opus-5",
            "display_name": "Claude Opus 5",
            "max_input_tokens": 1_000_000,
            "max_tokens": 128_000,
            "capabilities": [
                "thinking": [
                    "supported": true,
                    "types": ["adaptive": ["supported": true], "enabled": ["supported": false]]
                ],
                "effort": [
                    "supported": true,
                    "low": ["supported": true],
                    "medium": ["supported": true],
                    "high": ["supported": true],
                    "xhigh": ["supported": true]
                ]
            ]
        ]
        let decoded = try #require(AnthropicProvider.decodeModel(adaptive))
        #expect(decoded.reasoning?.mode == .adaptive)
        #expect(decoded.maxOutputTokens == 128_000)
        #expect(decoded.contextWindow == 1_000_000)
        #expect(decoded.reasoning?.effortLevels.contains(.xhigh) == true)

        let budgeted: [String: Any] = [
            "id": "claude-haiku-4-5",
            "capabilities": [
                "thinking": [
                    "supported": true,
                    "types": ["adaptive": ["supported": false], "enabled": ["supported": true]]
                ],
                "effort": ["supported": false]
            ]
        ]
        let decodedBudgeted = try #require(AnthropicProvider.decodeModel(budgeted))
        #expect(decodedBudgeted.reasoning?.mode == .budgeted)
        #expect(decodedBudgeted.reasoning?.sendsEffortParameter == false)
    }

    @Test("A payload with no capabilities object leaves reasoning unknown rather than guessing")
    func missingCapabilitiesStaysUnknown() throws {
        let decoded = try #require(AnthropicProvider.decodeModel(["id": "claude-future-9"]))
        #expect(decoded.reasoning == nil)
    }

    @Test("Gemini model metadata decodes thinking support and token limits")
    func geminiDecoding() throws {
        let thinking: [String: Any] = [
            "name": "models/gemini-3.6-flash",
            "displayName": "Gemini 3.6 Flash",
            "supportedGenerationMethods": ["generateContent"],
            "inputTokenLimit": 1_048_576,
            "outputTokenLimit": 65_536,
            "thinking": true
        ]
        let decoded = try #require(GeminiProvider.decodeModel(thinking))
        #expect(decoded.id == "gemini-3.6-flash", "the models/ prefix must be stripped")
        #expect(decoded.maxOutputTokens == 65_536)
        #expect(decoded.reasoning?.mode == .effortOnly)

        let embedding: [String: Any] = [
            "name": "models/text-embedding-004",
            "supportedGenerationMethods": ["embedContent"]
        ]
        #expect(GeminiProvider.decodeModel(embedding) == nil, "non-chat models are filtered out")
    }

    @Test("Reasoning support clamps an effort the model does not offer")
    func reasoningClamps() {
        let support = AIReasoningSupport(mode: .adaptive, effortLevels: [.low, .medium, .high])
        #expect(support.clampedEffort(.xhigh) == .high)
        #expect(support.clampedEffort(.medium) == .medium)
        #expect(AIReasoningSupport.unsupported.clampedEffort(.high) == nil)
    }

    @Test("Budgeted models never advertise the effort parameter")
    func budgetedNeverSendsEffort() {
        let budgeted = AIReasoningSupport(mode: .budgeted, effortLevels: [.low, .medium, .high])
        #expect(budgeted.sendsEffortParameter == false)
        let adaptive = AIReasoningSupport(mode: .adaptive, effortLevels: [.low])
        #expect(adaptive.sendsEffortParameter)
    }
}
