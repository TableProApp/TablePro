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

    @Test("Live provider metadata wins over the catalog")
    func liveMetadataWins() throws {
        let live = AIModelInfo(
            id: "claude-haiku-4-5",
            reasoning: AIReasoningSupport(mode: .adaptive, effortLevels: [.low, .medium, .high, .xhigh])
        )
        #expect(try claudeDescriptor().supportedEffortLevels(for: live) == [.low, .medium, .high, .xhigh])
    }

    // Before any list loads, a send reads the bundled or cached catalog, never the network.
    @Test("Without a loaded list the catalog supplies the model's levels")
    func catalogFallback() throws {
        let reference = AIModelReference(file: try AIModelReferenceFixtures.file)
        let source = AIModelSource(key: "openai", api: "responses", hidesUnknown: true, liveOrdered: false)
        let info = AIModelCatalog().info(providerID: UUID(), source: source, modelID: "gpt-5.6-sol", reference: reference)
        let openAI = try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.openAI.rawValue))
        #expect(openAI.supportedEffortLevels(for: info) == [.low, .medium, .high, .xhigh, .max])
        #expect(openAI.supportedEffortLevels(for: nil).isEmpty, "no level is guessed for a model nothing describes")
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

    /// The chat panel reads model lists while a Save in Settings refreshes them. Taking a refresh
    /// token there cancelled the Save's refresh, and a failed panel fetch then left no list at all.
    @Test("A chat panel answer lands when nothing changed since it started, and never cancels a refresh")
    func panelAnswerLandsBesideARefresh() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let token = catalog.beginRefresh(providerID: provider)
        let revision = catalog.revision(providerID: provider)
        catalog.store(providerID: provider, models: [AIModelInfo(id: "panel")], ifUnchangedSince: revision)
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "panel") != nil)
        catalog.finishRefresh(providerID: provider, token: token, models: [AIModelInfo(id: "saved")])
        #expect(catalog.fetchedInfo(providerID: provider, modelID: "saved") != nil)
    }

    @Test("A chat panel answer is dropped once a Save stored, removed or began a refresh after it started")
    func panelAnswerIsDroppedAfterASave() {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let writes: [(AIModelCatalog) -> Void] = [
            { $0.store(providerID: provider, models: [AIModelInfo(id: "saved")]) },
            { $0.remove(providerID: provider) },
            { _ = $0.beginRefresh(providerID: provider) }
        ]
        for write in writes {
            let revision = catalog.revision(providerID: provider)
            write(catalog)
            catalog.store(providerID: provider, models: [AIModelInfo(id: "late")], ifUnchangedSince: revision)
            #expect(catalog.fetchedInfo(providerID: provider, modelID: "late") == nil)
        }
    }

    @Test("A refresh fetches through the transport it is given")
    func refreshFetchesThroughTheTransport() async {
        let catalog = AIModelCatalog()
        let provider = UUID()
        let config = AIProviderConfig(id: provider, type: .custom, endpoint: "http://localhost:1")
        await catalog.refresh(config: config, using: ListedModelsTransport(ids: ["a", "b"]))
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

    private static func anthropicModel(
        _ id: String,
        disabled: Bool,
        efforts: [String],
        images: Bool = true,
        lifecycle: String = "active"
    ) -> [String: Any] {
        var effort: [String: Any] = ["supported": !efforts.isEmpty]
        for level in ["low", "medium", "high", "xhigh", "max"] {
            effort[level] = ["supported": efforts.contains(level)]
        }
        return [
            "id": id,
            "display_name": "Claude",
            "max_input_tokens": 1_000_000,
            "max_tokens": 128_000,
            "lifecycle": lifecycle,
            "created_at": "2026-10-20T00:00:00Z",
            "capabilities": [
                "image_input": ["supported": images],
                "thinking": [
                    "supported": true,
                    "types": [
                        "adaptive": ["supported": true],
                        "enabled": ["supported": false],
                        "disabled": ["supported": disabled]
                    ]
                ],
                "effort": effort
            ]
        ]
    }

    // Opus 5.5 answers `thinking: disabled` with a 400, so it always reasons; Opus 5 can be turned off.
    @Test("Anthropic capabilities decode the levels, max, Off and image input the API states")
    func anthropicCapabilityDecoding() throws {
        let always = try #require(AnthropicProvider.decodeModel(Self.anthropicModel(
            "claude-opus-5-5",
            disabled: false,
            efforts: ["low", "medium", "high", "xhigh", "max"],
            images: false
        )))
        let reasoning = try #require(always.reasoning)
        #expect(reasoning.mode == .adaptive)
        #expect(reasoning.effortLevels == [.low, .medium, .high, .xhigh, .max])
        #expect(!reasoning.effortLevels.contains(.minimal), "Minimal is not an Anthropic level")
        #expect(reasoning.isMandatory)
        #expect(!reasoning.canTurnOff)
        #expect(always.supportsImages == false)
        #expect(always.maxOutputTokens == 128_000)
        #expect(always.released != nil)

        let optional = try #require(AnthropicProvider.decodeModel(Self.anthropicModel(
            "claude-opus-5",
            disabled: true,
            efforts: ["low", "medium", "high", "xhigh"]
        )))
        #expect(optional.reasoning?.canTurnOff == true)
        #expect(optional.reasoning?.isMandatory == false)
        #expect(optional.supportsImages == true)

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

    @Test("A deprecated Claude model is marked, with its retirement date")
    func anthropicLifecycle() throws {
        var json = Self.anthropicModel("claude-sonnet-4-5", disabled: true, efforts: [], lifecycle: "deprecated")
        json["retires_at"] = "2026-11-30T00:00:00Z"
        let model = try #require(AnthropicProvider.decodeModel(json))
        #expect(model.isDeprecated)
        #expect(model.retiresAt == ISO8601DateFormatter().date(from: "2026-11-30T00:00:00Z"))
    }

    @Test("A payload with no capabilities object leaves reasoning unknown rather than guessing")
    func missingCapabilitiesStaysUnknown() throws {
        let decoded = try #require(AnthropicProvider.decodeModel(["id": "claude-future-9"]))
        #expect(decoded.reasoning == nil)
    }

    @Test("Gemini model metadata decodes its name and token limits")
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
        #expect(decoded.displayName == "Gemini 3.6 Flash")
        #expect(decoded.maxOutputTokens == 65_536)

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
        #expect(support.clampedEffort(.max) == .high)
        #expect(support.clampedEffort(.medium) == .medium)
        #expect(AIReasoningSupport.unsupported.clampedEffort(.high) == nil)
    }

    // A saved Off reaches only a model that takes it; one that always reasons runs its lowest level instead.
    @Test("Off is sent only where the model takes an explicit off")
    func offClamps() {
        let explicit = AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .high], canTurnOff: true)
        let always = AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .high], isMandatory: true)
        let optional = AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .high])
        #expect(explicit.clampedEffort(.off) == .off)
        #expect(always.clampedEffort(.off) == .low)
        #expect(optional.clampedEffort(.off) == nil)
    }

    @Test("The preselected level is the server's default, never above High")
    func preferredEffortIsCapped() {
        let maxDefault = AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .high, .max], defaultEffort: .max)
        let lowDefault = AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium], defaultEffort: .low)
        let noDefault = AIReasoningSupport(mode: .effortOnly, effortLevels: [.high])
        #expect(maxDefault.preferredEffort == .high)
        #expect(lowDefault.preferredEffort == .low)
        #expect(noDefault.preferredEffort == .high)
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
