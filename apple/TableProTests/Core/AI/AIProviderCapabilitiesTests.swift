//
//  AIProviderCapabilitiesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIProviderCapabilitiesTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func descriptor(_ type: AIProviderType) -> AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: type.rawValue)
    }

    @Test("Copilot hides max output tokens and endpoint, shows telemetry, fetches a live model list")
    func copilotCapabilities() {
        let copilot = descriptor(.copilot)
        #expect(copilot?.allowsMaxOutputTokens == false)
        #expect(copilot?.allowsEndpointConfiguration == false)
        #expect(copilot?.allowsNameConfiguration == false)
        #expect(copilot?.showsTelemetryToggle == true)
        #expect(copilot?.defaultTelemetryEnabled == true)
        #expect(copilot?.fetchesModelList == true)
    }

    @Test("ChatGPT Codex hides max output tokens and endpoint, uses curated models only")
    func chatgptCodexCapabilities() {
        let codex = descriptor(.chatgptCodex)
        #expect(codex?.allowsMaxOutputTokens == false)
        #expect(codex?.allowsEndpointConfiguration == false)
        #expect(codex?.fetchesModelList == false)
        #expect(codex?.showsTelemetryToggle == false)
        #expect(codex?.curatedModels.isEmpty == false)
    }

    @Test("HTTP API-key providers accept max output tokens, a configurable endpoint, and model fetch")
    func standardHTTPProviders() {
        for type in [AIProviderType.openAI, .claude, .gemini, .xai, .openRouter, .ollama] {
            let provider = descriptor(type)
            #expect(provider?.allowsMaxOutputTokens == true, "\(type.rawValue) should accept max output tokens")
            #expect(provider?.allowsEndpointConfiguration == true, "\(type.rawValue) should allow endpoint config")
            #expect(provider?.fetchesModelList == true, "\(type.rawValue) should fetch a model list")
        }
    }

    @Test("Every provider type has a registered descriptor")
    func everyTypeHasDescriptor() {
        for type in AIProviderType.allCases {
            #expect(descriptor(type) != nil, "\(type.rawValue) must have a registered descriptor")
        }
    }

    @Test("The OpenAI-compatible family is registered from one list, on one transport")
    func openAICompatibleFamilySharesATransport() {
        for type in AIProviderType.openAICompatibleFamily {
            let config = AIProviderConfig(type: type, model: "m", endpoint: "http://localhost:1")
            #expect(
                descriptor(type)?.makeProvider(config, nil) is OpenAICompatibleProvider,
                "\(type.rawValue) must build the OpenAI-compatible transport"
            )
        }
    }

    /// Neither transport sends an effort: Gemini builds no thinking configuration, and Ollama's
    /// native route takes `think` rather than `reasoning_effort`. A picker there changed nothing.
    @Test("A provider whose transport ignores reasoning effort offers no effort picker")
    func noEffortPickerWhereTheTransportIgnoresIt() {
        for type in [AIProviderType.gemini, .ollama] {
            #expect(descriptor(type)?.supportsReasoning == false, "\(type.rawValue) must not offer reasoning")
            #expect(descriptor(type)?.supportedEffortLevels(forModelID: "any-model").isEmpty == true)
        }
    }

    @Test("The provider's own model list narrows reasoning and images per model")
    func fetchedModelInfoNarrowsTheEnvelope() throws {
        let router = try #require(descriptor(.openRouter))
        let textOnly = AIModelInfo(id: "m", modalities: [.text], reasoning: .unsupported)
        #expect(router.supportsImages(fetched: textOnly) == false)
        #expect(router.supportedEffortLevels(forModelID: "m", fetched: textOnly).isEmpty)

        let capable = AIModelInfo(
            id: "m",
            modalities: [.text, .image],
            reasoning: AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high])
        )
        #expect(router.supportsImages(fetched: capable))
        #expect(router.supportedEffortLevels(forModelID: "m", fetched: capable) == [.low, .medium, .high])
    }

    /// A plain OpenAI model list carries an id and nothing else. Reading that silence as "text
    /// only" would have closed images and reasoning for every model on such a server.
    @Test("A model list that says nothing about a model leaves the envelope open")
    func silentModelInfoLeavesTheEnvelopeOpen() throws {
        let router = try #require(descriptor(.openRouter))
        let silent = AIModelInfo(id: "m")
        #expect(silent.supportsImages == nil)
        #expect(router.supportsImages(fetched: silent))
        #expect(router.supportedEffortLevels(forModelID: "m", fetched: silent) == [.low, .medium, .high])
    }

    @Test("Only the custom provider allows the name field")
    func nameFieldOnlyForCustom() {
        #expect(descriptor(.custom)?.allowsNameConfiguration == true)
        #expect(descriptor(.openAI)?.allowsNameConfiguration == false)
        #expect(descriptor(.copilot)?.allowsNameConfiguration == false)
    }

    @Test("Telemetry toggle is exclusive to Copilot")
    func telemetryToggleOnlyForCopilot() {
        for type in [AIProviderType.openAI, .claude, .gemini, .xai, .chatgptCodex, .custom, .ollama] {
            #expect(descriptor(type)?.showsTelemetryToggle == false, "\(type.rawValue) must not show telemetry")
        }
    }

    /// The effort is saved with the provider's own model, and the chat panel can send another.
    /// GPT-5.6 offers Minimal, and picking GPT-5.5 in the panel sent `minimal` to a model that
    /// takes low to extra high.
    @Test("The effort sent is fitted to the model the chat panel picked")
    func effortIsFittedToTheSentModel() {
        let chatGPT = AIProviderConfig(type: .chatgptCodex, model: "gpt-5.6-sol", reasoningEffort: .minimal)
        let catalog = AIModelCatalog()
        #expect(AIProviderFactory.reasoningEffort(.minimal, config: chatGPT, model: "gpt-5.6-sol", catalog: catalog) == .minimal)
        #expect(AIProviderFactory.reasoningEffort(.minimal, config: chatGPT, model: "gpt-5.5", catalog: catalog) == .low)
    }

    @Test("No effort goes to a model its server lists as not reasoning, or to a provider without reasoning")
    func noEffortWhereNoneIsTaken() {
        let catalog = AIModelCatalog()
        let router = AIProviderConfig(preset: .requesty)
        var configured = router
        configured.reasoningEffort = .high
        catalog.store(providerID: router.id, models: [AIModelInfo(id: "alibaba/qwen-max", reasoning: .unsupported)])
        #expect(AIProviderFactory.reasoningEffort(.high, config: configured, model: "alibaba/qwen-max", catalog: catalog) == nil)

        let copilot = AIProviderConfig(type: .copilot, model: "gpt-5.5", reasoningEffort: .high)
        #expect(AIProviderFactory.reasoningEffort(.high, config: copilot, model: "gpt-5.5", catalog: catalog) == nil)
    }

    @Test("A Meta provider sends its effort to any Muse chat model the panel picks")
    func metaEffortReachesEveryMuseModel() {
        var meta = AIProviderConfig(preset: .meta)
        meta.model = "muse-spark-1.3"
        meta.reasoningEffort = .xhigh
        let catalog = AIModelCatalog()
        for model in ["muse-spark-1.3", "muse-spark-1.2", "muse-wonder-1.0", "muse-ember-1.0"] {
            #expect(AIProviderFactory.reasoningEffort(.xhigh, config: meta, model: model, catalog: catalog) == .xhigh, "\(model)")
        }
    }

    /// Meta runs its most expensive level when no effort is sent, and inline suggestions and a
    /// provider synced from an older build send none.
    @Test("A Muse model sent no effort gets its default, and other models stay without one")
    func mandatoryReasoningGetsItsDefault() {
        let meta = AIProviderConfig(preset: .meta)
        let catalog = AIModelCatalog()
        #expect(AIProviderFactory.reasoningEffort(nil, config: meta, model: "muse-wonder-1.0", catalog: catalog) == .high)
        let openAI = AIProviderConfig(type: .openAI, model: "gpt-5.5")
        #expect(AIProviderFactory.reasoningEffort(nil, config: openAI, model: "gpt-5.5", catalog: catalog) == nil)
    }

    @Test("Effort levels for every provider without a preset are what they were")
    func presetFreeLevelsAreUnchanged() throws {
        #expect(try #require(descriptor(.openRouter)).supportedEffortLevels(forModelID: "m") == [.low, .medium, .high])
        #expect(try #require(descriptor(.custom)).supportedEffortLevels(forModelID: "m") == [.low, .medium, .high])
        #expect(try #require(descriptor(.openAI)).supportedEffortLevels(forModelID: "gpt-5.5") == [.low, .medium, .high, .xhigh])
        #expect(try #require(descriptor(.copilot)).supportedEffortLevels(forModelID: "gpt-5.5").isEmpty)
    }

    /// Inline suggestions send no effort where a model allows it. A Muse model has no such choice,
    /// and sending none there ran Meta's most expensive level on every keystroke pause.
    @Test("Inline suggestions send the saved effort only to a model that always reasons")
    func inlineEffortOnlyWhereRequired() {
        var meta = AIProviderConfig(preset: .meta)
        meta.reasoningEffort = .minimal
        let openAI = AIProviderConfig(type: .openAI, model: "gpt-5.5", reasoningEffort: .high)
        let catalog = AIModelCatalog()
        #expect(AIProviderFactory.reasoningEffort(
            .minimal, config: meta, model: "muse-spark-1.3", onlyWhereRequired: true, catalog: catalog
        ) == .minimal)
        #expect(AIProviderFactory.reasoningEffort(
            nil, config: meta, model: "muse-ember-1.0", onlyWhereRequired: true, catalog: catalog
        ) == .high)
        #expect(AIProviderFactory.reasoningEffort(
            .high, config: openAI, model: "gpt-5.5", onlyWhereRequired: true, catalog: catalog
        ) == nil)
    }

    /// OpenAI rejects a reasoning effort for its non-reasoning models, which the chat panel lists
    /// beside the reasoning ones.
    @Test("No effort goes to an OpenAI model that does not reason")
    func noEffortForOpenAINonReasoningModels() throws {
        let openAI = AIProviderConfig(type: .openAI, model: "gpt-5.5", reasoningEffort: .high)
        let catalog = AIModelCatalog()
        for model in ["gpt-4.1", "gpt-4o-mini", "chatgpt-4o-latest", "gpt-5-chat-latest", "gpt-3.5-turbo"] {
            #expect(AIProviderFactory.reasoningEffort(.high, config: openAI, model: model, catalog: catalog) == nil, "\(model)")
        }
        #expect(AIProviderFactory.reasoningEffort(.high, config: openAI, model: "gpt-5.5", catalog: catalog) == .high)
        #expect(try #require(descriptor(.openAI)).supportedEffortLevels(forModelID: "gpt-4.1").isEmpty)
    }
}
