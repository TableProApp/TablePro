//
//  AIProviderCapabilitiesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIProviderDescriptor capabilities")
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
