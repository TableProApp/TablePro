//
//  AISettingsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AISettings")
struct AISettingsTests {
    @Test("default has enabled true")
    func defaultEnabledIsTrue() {
        #expect(AISettings.default.enabled == true)
    }

    @Test("decoding without enabled key defaults to true")
    func decodingWithoutEnabledDefaultsToTrue() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.enabled == true)
    }

    @Test("decoding with enabled false sets it correctly")
    func decodingWithEnabledFalse() throws {
        let json = "{\"enabled\": false}"
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.enabled == false)
    }
}

// MARK: - Active Provider

@Suite("AISettings.activeProvider")
struct AISettingsActiveProviderTests {
    private func makeProvider(name: String = "Test", type: AIProviderType = .claude) -> AIProviderConfig {
        AIProviderConfig(name: name, type: type)
    }

    @Test("Returns nil when activeProviderID is nil")
    func nilWhenIDNotSet() {
        let settings = AISettings(providers: [makeProvider()], activeProviderID: nil)
        #expect(settings.activeProvider == nil)
        #expect(settings.hasActiveProvider == false)
    }

    @Test("Returns nil when activeProviderID does not match any provider")
    func nilWhenIDMissing() {
        let provider = makeProvider()
        let settings = AISettings(providers: [provider], activeProviderID: UUID())
        #expect(settings.activeProvider == nil)
        #expect(settings.hasActiveProvider == false)
    }

    @Test("Returns the matching provider when activeProviderID matches")
    func returnsMatchingProvider() {
        let target = makeProvider(name: "Active")
        let other = makeProvider(name: "Other")
        let settings = AISettings(providers: [other, target], activeProviderID: target.id)
        #expect(settings.activeProvider?.id == target.id)
        #expect(settings.activeProvider?.name == "Active")
        #expect(settings.hasActiveProvider == true)
    }

    @Test("hasCopilotConfigured detects a Copilot provider")
    func hasCopilotConfigured() {
        let claude = makeProvider(name: "Claude", type: .claude)
        let copilot = makeProvider(name: "Copilot", type: .copilot)

        let withoutCopilot = AISettings(providers: [claude], activeProviderID: claude.id)
        #expect(withoutCopilot.hasCopilotConfigured == false)

        let withCopilot = AISettings(providers: [claude, copilot], activeProviderID: claude.id)
        #expect(withCopilot.hasCopilotConfigured == true)
    }

    @Test("Active provider survives decode round trip")
    func decodeRoundTrip() throws {
        let provider = makeProvider()
        let settings = AISettings(providers: [provider], activeProviderID: provider.id)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(decoded.activeProvider?.id == provider.id)
    }

    @Test("Decoding without activeProviderID defaults to nil")
    func decodingWithoutActiveProviderDefaultsToNil() throws {
        let json = #"{"enabled": true, "providers": []}"#
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.activeProviderID == nil)
        #expect(settings.activeProvider == nil)
    }
}
