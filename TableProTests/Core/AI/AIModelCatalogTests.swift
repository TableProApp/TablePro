//
//  AIModelCatalogTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIModelCatalogTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func claudeDescriptor() throws -> AIProviderDescriptor {
        try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.claude.rawValue))
    }

    @Test("Live provider metadata wins over the static overlay")
    func liveMetadataWins() throws {
        let live = AIModelInfo(
            id: "claude-haiku-4-5",
            reasoning: AIReasoningSupport(mode: .adaptive, effortLevels: [.low, .medium, .high, .xhigh])
        )
        let levels = try claudeDescriptor().supportedEffortLevels(forModelID: "claude-haiku-4-5", fetched: live)
        #expect(levels == [.low, .medium, .high, .xhigh], "live metadata must override the offline table")
    }

    /// OpenAI has no effort resolver and does not curate gpt-5.4, and the plain default lacks
    /// Extra High, so only the offline table can supply this answer.
    @Test("Without live metadata the overlay supplies the answer")
    func overlayFallback() throws {
        let openAI = try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.openAI.rawValue))
        #expect(openAI.curatedModel(forID: "gpt-5.4") == nil)
        #expect(openAI.supportedEffortLevels(forModelID: "gpt-5.4", fetched: nil) == [.low, .medium, .high, .xhigh])
    }

    @Test("Storing an empty list never erases what is already known")
    func emptyStoreIsIgnored() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let live = AIModelInfo(id: "m", reasoning: AIReasoningSupport(mode: .adaptive, effortLevels: [.high]))
        catalog.store(providerID: provider, models: [live])
        catalog.store(providerID: provider, models: [])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "m") != nil)
    }

    /// Two custom providers are two servers. Keyed by provider type, a list fetched from one
    /// replaced what was known about the other.
    @Test("Two providers of the same type keep separate lists")
    func listsAreKeptPerProvider() {
        let catalog = AIModelCatalog()
        let router = UUID()
        let local = UUID()
        catalog.store(providerID: router, models: [AIModelInfo(id: "shared", modalities: [.text])])
        catalog.store(providerID: local, models: [AIModelInfo(id: "shared", modalities: [.text, .image])])

        #expect(catalog.fetchedInfo(providerID: router, modelID: "shared")?.supportsImages == false)
        #expect(catalog.fetchedInfo(providerID: local, modelID: "shared")?.supportsImages == true)
    }

    @Test("A newer list replaces the older one for the same provider")
    func newerListReplacesTheOlder() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        catalog.store(providerID: provider, models: [AIModelInfo(id: "old")])
        catalog.store(providerID: provider, models: [AIModelInfo(id: "new")])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "old") == nil)
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "new") != nil)
    }

    @Test("A refresh that lands stores its list")
    func refreshStoresItsList() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let token = catalog.beginRefresh(providerID: provider)
        catalog.finishRefresh(providerID: provider, token: token, models: [AIModelInfo(id: "m")])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "m") != nil)
    }

    /// Two Saves in a row start two refreshes. The first can answer last, from the server the
    /// provider no longer points at.
    @Test("An older refresh that lands after a newer one is dropped")
    func olderRefreshIsDropped() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let first = catalog.beginRefresh(providerID: provider)
        let second = catalog.beginRefresh(providerID: provider)
        catalog.finishRefresh(providerID: provider, token: second, models: [AIModelInfo(id: "new-server")])
        catalog.finishRefresh(providerID: provider, token: first, models: [AIModelInfo(id: "old-server")])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "new-server") != nil)
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "old-server") == nil)
    }

    @Test("A refresh that a Save with a loaded list overtook is dropped")
    func refreshOvertakenByAStoreIsDropped() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let token = catalog.beginRefresh(providerID: provider)
        catalog.store(providerID: provider, models: [AIModelInfo(id: "saved")])
        catalog.finishRefresh(providerID: provider, token: token, models: [AIModelInfo(id: "late")])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "saved") != nil)
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "late") == nil)
    }

    @Test("A refresh that lands after its provider was removed does not bring it back")
    func refreshAfterRemovalIsDropped() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let token = catalog.beginRefresh(providerID: provider)
        catalog.remove(providerID: provider)
        catalog.finishRefresh(providerID: provider, token: token, models: [AIModelInfo(id: "m")])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "m") == nil)
    }

    @Test("A refresh fetches through the transport it is given")
    func refreshFetchesThroughTheTransport() async {
        let catalog = AIModelCatalog()
        let provider = UUID()
        await catalog.refresh(providerID: provider, using: ListedModelsTransport(ids: ["a", "b"]))
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "b") != nil)
    }

    @Test("A provider nothing was fetched for has no entry, and a removed one loses its own")
    func unknownAndRemovedProvidersHaveNoEntry() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "m") == nil)
        #expect(catalog.fetchedInfo(providerID: nil, modelID: "m") == nil)

        catalog.store(providerID: provider, models: [AIModelInfo(id: "m")])
        catalog.remove(providerID: provider)
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "m") == nil)
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

private final class ListedModelsTransport: ChatTransport, @unchecked Sendable {
    private let ids: [String]

    init(ids: [String]) {
        self.ids = ids
    }

    func streamChat(turns: [ChatTurnWire], options: ChatTransportOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        ids.map { AIModelInfo(id: $0) }
    }

    func testConnection() async throws -> Bool { true }
}
