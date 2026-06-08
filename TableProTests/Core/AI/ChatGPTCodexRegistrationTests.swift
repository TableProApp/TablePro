//
//  ChatGPTCodexRegistrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatGPTCodex provider registration")
struct ChatGPTCodexRegistrationTests {
    @Test("ChatGPT Codex uses the OAuth auth style")
    func authStyleIsOAuth() {
        #expect(AIProviderType.chatgptCodex.authStyle == .oauth)
    }

    @Test("ChatGPT Codex is a known provider type")
    func isKnownType() {
        #expect(AIProviderType.allCases.contains(.chatgptCodex))
        #expect(AIProviderType(rawValue: "chatgptCodex") == .chatgptCodex)
    }

    @Test("Registry builds a ChatGPTCodexProvider for the descriptor")
    func descriptorMakesCodexProvider() {
        AIProviderRegistration.registerAll()
        let descriptor = AIProviderRegistry.shared.descriptor(for: AIProviderType.chatgptCodex.rawValue)
        #expect(descriptor != nil)
        #expect(descriptor?.requiresAPIKey == false)

        let config = AIProviderConfig(type: .chatgptCodex, model: "gpt-5.5")
        let provider = descriptor?.makeProvider(config, nil)
        #expect(provider is ChatGPTCodexProvider)
    }
}
