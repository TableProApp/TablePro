//
//  AISettingsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
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
        let data = Data(json.utf8)
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.enabled == true)
    }

    @Test("decoding with enabled false sets it correctly")
    func decodingWithEnabledFalse() throws {
        let json = "{\"enabled\": false}"
        let data = Data(json.utf8)
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.enabled == false)
    }

    @Test("Default settings include schema and current query, exclude query results")
    func defaultsForContextFlags() {
        let settings = AISettings.default
        #expect(settings.includeSchema == true)
        #expect(settings.includeCurrentQuery == true)
        #expect(settings.includeQueryResults == false)
    }

    @Test("Memberwise init uses the same context defaults as AISettings.default")
    func memberwiseInitMatchesDefault() {
        let settings = AISettings()
        #expect(settings.includeSchema == AISettings.default.includeSchema)
        #expect(settings.includeCurrentQuery == AISettings.default.includeCurrentQuery)
        #expect(settings.includeQueryResults == AISettings.default.includeQueryResults)
    }

    @Test("Decoding empty JSON yields the same context defaults as AISettings.default")
    func decodingEmptyJSONMatchesDefault() throws {
        let data = Data("{}".utf8)
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.includeSchema == AISettings.default.includeSchema)
        #expect(settings.includeCurrentQuery == AISettings.default.includeCurrentQuery)
        #expect(settings.includeQueryResults == AISettings.default.includeQueryResults)
    }

    @Test("Tool call limit defaults to 25 and is enabled")
    func defaultToolRoundtripLimit() {
        #expect(AISettings.default.maxToolRoundtrips == 25)
        #expect(AISettings.default.maxToolRoundtripsEnabled == true)
        #expect(AISettings.default.effectiveMaxToolRoundtrips == 25)
    }

    @Test("Settings saved before the tool call limit existed decode to the default")
    func decodingWithoutToolRoundtripKeysUsesDefault() throws {
        let data = Data("{}".utf8)
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.maxToolRoundtrips == AISettings.defaultMaxToolRoundtrips)
        #expect(settings.maxToolRoundtripsEnabled == true)
    }

    @Test("Stored tool call limit values are preserved on decode")
    func storedToolRoundtripValuesAreRespected() throws {
        let json = #"{"maxToolRoundtrips": 60, "maxToolRoundtripsEnabled": false}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.maxToolRoundtrips == 60)
        #expect(settings.maxToolRoundtripsEnabled == false)
    }

    @Test("Turning the limit off makes it unlimited")
    func disabledLimitIsUnlimited() {
        let settings = AISettings(maxToolRoundtrips: 30, maxToolRoundtripsEnabled: false)
        #expect(settings.effectiveMaxToolRoundtrips == nil)
    }

    @Test("Out of range tool call limits clamp to the supported range")
    func toolRoundtripLimitClamps() {
        let tooHigh = AISettings(maxToolRoundtrips: 5_000, maxToolRoundtripsEnabled: true)
        #expect(tooHigh.effectiveMaxToolRoundtrips == AISettings.maxToolRoundtripsRange.upperBound)

        let tooLow = AISettings(maxToolRoundtrips: 0, maxToolRoundtripsEnabled: true)
        #expect(tooLow.effectiveMaxToolRoundtrips == AISettings.maxToolRoundtripsRange.lowerBound)
    }

    @Test("Stored false values for context flags are preserved on decode")
    func storedFalseFlagsAreRespected() throws {
        let json = #"{"includeSchema": false, "includeCurrentQuery": false, "includeQueryResults": false}"#
        let data = Data(json.utf8)
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.includeSchema == false)
        #expect(settings.includeCurrentQuery == false)
        #expect(settings.includeQueryResults == false)
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
        let data = Data(json.utf8)
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.activeProviderID == nil)
        #expect(settings.activeProvider == nil)
    }
}
