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
}
