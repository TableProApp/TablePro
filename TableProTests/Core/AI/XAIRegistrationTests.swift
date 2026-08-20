//
//  XAIRegistrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("xAI provider registration")
struct XAIRegistrationTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func descriptor() -> AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: AIProviderType.xai.rawValue)
    }

    @Test("xAI allows an optional API key and is a known type")
    func authStyleAndType() {
        #expect(AIProviderType.xai.authStyle == .optionalApiKey)
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

    @Test("xAI curates the current Grok chat models and no retired slugs")
    func curatedModels() {
        let ids = descriptor()?.curatedModels.map(\.id) ?? []
        #expect(ids == ["grok-4.5", "grok-4.3"])
        for retired in ["grok-4", "grok-4-0709", "grok-3", "grok-3-mini", "grok-code-fast-1"] {
            #expect(!ids.contains(retired), "retired slug \(retired) redirects and mis-bills; must not be curated")
        }
    }

    @Test("xAI never offers an effort level the API rejects")
    func effortLevels() {
        let levels = descriptor()?.supportedEffortLevels(forModelID: "grok-4.5") ?? []
        #expect(levels == [.low, .medium, .high])
        #expect(!levels.contains(.minimal))
        #expect(!levels.contains(.xhigh))
        let fallback = descriptor()?.supportedEffortLevels(forModelID: "grok-unknown") ?? []
        #expect(!fallback.contains(.minimal))
        #expect(!fallback.contains(.xhigh))
    }

    @Test("A key selects the api.x.ai Responses provider, no key selects the Grok subscription provider")
    func makeProviderBranchesOnKey() {
        let config = AIProviderConfig(type: .xai, model: "grok-4.5")
        #expect(descriptor()?.makeProvider(config, "xai-test-key") is OpenAIResponsesProvider)
        #expect(descriptor()?.makeProvider(config, nil) is XAIGrokProvider)
        #expect(descriptor()?.makeProvider(config, "") is XAIGrokProvider)
    }
}
