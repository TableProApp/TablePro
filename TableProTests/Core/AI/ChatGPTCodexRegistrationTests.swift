//
//  ChatGPTCodexRegistrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ChatGPTCodexRegistrationTests {
    @Test("ChatGPT Codex uses the OAuth auth style")
    func authStyleIsOAuth() {
        #expect(AIProviderType.chatgptCodex.authStyle == .oauth)
    }

    @Test("Registry builds a ChatGPTCodexProvider for the descriptor")
    func descriptorMakesCodexProvider() {
        AIProviderRegistration.registerAll()
        let descriptor = AIProviderRegistry.shared.descriptor(for: AIProviderType.chatgptCodex.rawValue)
        #expect(descriptor != nil)
        #expect(AIProviderType.chatgptCodex.authStyle == .oauth)

        let config = AIProviderConfig(type: .chatgptCodex, model: "gpt-5.5")
        let provider = descriptor?.makeProvider(config, nil)
        #expect(provider is ChatGPTCodexProvider)
    }
}
