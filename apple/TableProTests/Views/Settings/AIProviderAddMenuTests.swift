import Foundation
@testable import TablePro
import Testing

struct AIProviderAddMenuTests {
    private let everything = AIProviderAddMenu.groups { _ in true }

    @Test("Account sign-ins come first, Claude Agent with them")
    func signInGroup() {
        #expect(everything.signIn == [.type(.copilot), .type(.chatgptCodex), .type(.claudeAgent)])
    }

    @Test("API key providers list the built-in types, then the presets")
    func apiKeyGroup() {
        let types = AIProviderType.allCases
            .filter { $0 != .custom && $0.authStyle.usesAPIKey }
            .map(AIProviderAddChoice.type)
        let presets = AIProviderPreset.all.map { AIProviderAddChoice.preset($0.id) }
        #expect(everything.apiKey == types + presets)
        #expect(everything.apiKey.contains(.type(.openCode)))
    }

    @Test("Local servers go under On This Mac")
    func onThisMacGroup() {
        #expect(everything.onThisMac == [.type(.ollama), .type(.llamaCpp), .type(.mlx)])
    }

    @Test("Custom is offered once, last, and in no group")
    func customIsLast() {
        #expect(everything.includesCustom)
        let grouped = everything.signIn + everything.apiKey + everything.onThisMac
        #expect(!grouped.contains(.type(.custom)))
        #expect(!grouped.contains(.custom))
    }

    @Test("Every registered type is offered exactly once")
    func everyTypeOnce() {
        let grouped = everything.signIn + everything.apiKey + everything.onThisMac
        for type in AIProviderType.allCases where type != .custom {
            #expect(grouped.filter { $0 == .type(type) }.count == 1)
        }
    }

    @Test("A type with no registered descriptor is not offered")
    func unregisteredTypesAreDropped() {
        let groups = AIProviderAddMenu.groups { $0 != .copilot && $0 != .ollama }
        #expect(!groups.signIn.contains(.type(.copilot)))
        #expect(!groups.onThisMac.contains(.type(.ollama)))
    }

    // Presets are stored as .custom, so without the custom descriptor neither they nor Custom can be added.
    @Test("Presets and Custom need the custom descriptor")
    func presetsNeedCustom() {
        let groups = AIProviderAddMenu.groups { $0 != .custom }
        #expect(!groups.includesCustom)
        #expect(!groups.apiKey.contains { $0.preset != nil })
    }

    @Test("A preset choice makes a custom provider carrying the preset")
    func presetChoiceMakesACustomProvider() {
        let preset = AIProviderPreset.requesty
        let provider = AIProviderAddChoice.preset(preset.id).makeProvider { _ in nil }
        #expect(provider.type == .custom)
        #expect(provider.presetID == preset.id)
        #expect(provider.endpoint == preset.endpoint)
        #expect(provider.displayName == preset.displayName)
    }

    @Test("A type choice starts on the type's default endpoint and an empty model")
    func typeChoiceUsesDefaults() {
        let provider = AIProviderAddChoice.type(.ollama).makeProvider { _ in nil }
        #expect(provider.type == .ollama)
        #expect(provider.endpoint == AIProviderType.ollama.defaultEndpoint)
        #expect(provider.model.isEmpty)
        #expect(!provider.telemetryEnabled)
    }

    @Test("Every choice makes a provider with a fresh id")
    func choicesMakeFreshIDs() {
        let one = AIProviderAddChoice.custom.makeProvider { _ in nil }
        let two = AIProviderAddChoice.custom.makeProvider { _ in nil }
        #expect(one.id != two.id)
        #expect(one.type == .custom)
    }
}
