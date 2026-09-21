//
//  CustomProviderRegistrationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Custom provider registration")
struct CustomProviderRegistrationTests {
    private func descriptor() -> AIProviderDescriptor? {
        AIProviderRegistration.registerAll()
        return AIProviderRegistry.shared.descriptor(for: AIProviderType.custom.rawValue)
    }

    /// An OpenAI-compatible server with authentication turned off, such as a self-hosted vLLM or
    /// LM Studio, has no key to paste, and requiring one left Save permanently dimmed.
    @Test("A custom provider's API key is optional")
    func apiKeyIsOptional() {
        #expect(AIProviderType.custom.authStyle == .optionalApiKey)
        #expect(AIProviderType.custom.authStyle.usesAPIKey)
    }

    @Test("A custom provider still fetches its model list and takes an endpoint and a name")
    func keepsItsCapabilities() throws {
        let entry = try #require(descriptor())
        #expect(entry.allowsEndpointConfiguration)
        #expect(entry.allowsNameConfiguration)
        #expect(entry.fetchesModelList)
        #expect(entry.allowsMaxOutputTokens)
    }

    @Test("A custom provider builds the OpenAI-compatible transport with no key")
    func buildsWithoutAKey() throws {
        let entry = try #require(descriptor())
        let config = AIProviderConfig(type: .custom, model: "glm-4.6", endpoint: "https://api.z.ai/api/paas/v4")
        #expect(entry.makeProvider(config, nil) is OpenAICompatibleProvider)
        #expect(entry.makeProvider(config, "") is OpenAICompatibleProvider)
    }
}
