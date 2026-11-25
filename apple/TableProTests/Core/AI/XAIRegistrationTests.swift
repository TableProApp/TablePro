//
//  XAIRegistrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct XAIRegistrationTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func descriptor() -> AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: AIProviderType.xai.rawValue)
    }

    @Test("xAI takes an API key and is a known type")
    func authStyleAndType() {
        #expect(AIProviderType.xai.authStyle == .apiKey)
        #expect(AIProviderType.allCases.contains(.xai))
        #expect(AIProviderType(rawValue: "xai") == .xai)
        #expect(AIProviderType.xai.displayName == "xAI")
        #expect(AIProviderType.xai.defaultEndpoint == "https://api.x.ai")
    }

    @Test("xAI descriptor capabilities")
    func capabilities() {
        let xai = descriptor()
        #expect(xai != nil)
        #expect(xai?.supportsReasoning == true)
        #expect(xai?.supportsImages == true)
        #expect(xai?.allowsEndpointConfiguration == true)
        #expect(xai?.allowsMaxOutputTokens == true)
        #expect(xai?.fetchesModelList == true)
        #expect(xai?.allowsNameConfiguration == false)
        #expect(xai?.showsTelemetryToggle == false)
    }

    @Test("xAI offers no effort level for a model nothing describes")
    func effortLevels() {
        #expect(descriptor()?.supportedEffortLevels(for: nil).isEmpty == true)
    }

    @Test("xAI always talks to the api.x.ai Responses endpoint")
    func makeProviderIsResponses() {
        let config = AIProviderConfig(type: .xai, model: "grok-4.5")
        #expect(descriptor()?.makeProvider(config, "xai-test-key") is OpenAIResponsesProvider)
        #expect(descriptor()?.makeProvider(config, nil) is OpenAIResponsesProvider)
    }
}
