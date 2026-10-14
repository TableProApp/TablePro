//
//  AIProviderAccountProbesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIProviderAccountProbesTests {
    private func settings(enabled: Bool = true, _ types: AIProviderType...) -> AISettings {
        AISettings(enabled: enabled, providers: types.map { AIProviderConfig(type: $0) })
    }

    @Test("Nothing is probed when no provider is configured")
    func noProvidersProbesNothing() {
        #expect(AIProviderAccountProbes.types(toProbe: settings()).isEmpty)
    }

    @Test("Nothing is probed while AI is off, even with sign-in providers configured")
    func aiOffProbesNothing() {
        let configured = settings(enabled: false, .claudeAgent, .chatgptCodex)
        #expect(AIProviderAccountProbes.types(toProbe: configured).isEmpty)
    }

    @Test("Only the configured sign-in providers are probed")
    func onlyConfiguredProvidersAreProbed() {
        let configured = settings(.claudeAgent, .openAI, .gemini)
        #expect(AIProviderAccountProbes.types(toProbe: configured) == [.claudeAgent])
    }

    @Test("Every configured sign-in provider is probed once")
    func everyConfiguredSignInProviderIsProbed() {
        let configured = settings(.chatgptCodex, .claudeAgent, .claudeAgent)
        #expect(AIProviderAccountProbes.types(toProbe: configured) == [.chatgptCodex, .claudeAgent])
    }

    @Test("API key providers never need an account probe")
    func apiKeyProvidersAreNotProbed() {
        let configured = settings(.claude, .openAI, .openRouter, .gemini, .xai, .ollama, .custom, .copilot)
        #expect(AIProviderAccountProbes.types(toProbe: configured).isEmpty)
    }
}
