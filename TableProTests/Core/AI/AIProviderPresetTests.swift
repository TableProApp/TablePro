//
//  AIProviderPresetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIProviderPresetTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    @Test("Requesty needs a key, and its default Base URL resolves to its chat completions route")
    func requestyPreset() throws {
        let preset = AIProviderPreset.requesty
        #expect(preset.authStyle == .apiKey)
        #expect(preset.rejectsBadKeyWithForbidden)

        let config = AIProviderConfig(preset: preset)
        let style = config.type.endpointStyle
        #expect(style == .chatCompletions)
        #expect(
            AIEndpoint(config.endpoint, style: style)?.chatURL(model: "openai/gpt-5.5", style: style)?.absoluteString
                == "https://router.requesty.ai/v1/chat/completions"
        )
        #expect(
            AIEndpoint(config.endpoint, style: style)?.url(appending: style.modelsResource)?.absoluteString
                == "https://router.requesty.ai/v1/models"
        )
    }

    @Test("Opper needs a key, and its default Base URL resolves to its chat completions and models routes")
    func opperPreset() throws {
        let preset = AIProviderPreset.opper
        #expect(preset.authStyle == .apiKey)
        #expect(!preset.rejectsBadKeyWithForbidden)

        let config = AIProviderConfig(preset: preset)
        let style = config.type.endpointStyle
        #expect(style == .chatCompletions)
        #expect(
            AIEndpoint(config.endpoint, style: style)?.chatURL(model: "claude-sonnet-4-6", style: style)?.absoluteString
                == "https://api.opper.ai/v3/compat/chat/completions"
        )
        #expect(
            AIEndpoint(config.endpoint, style: style)?.url(appending: style.modelsResource)?.absoluteString
                == "https://api.opper.ai/v3/compat/models"
        )
    }

    @Test("Every preset has a unique id and an https endpoint the transport can resolve")
    func presetsAreWellFormed() {
        #expect(Set(AIProviderPreset.all.map(\.id)).count == AIProviderPreset.all.count)
        for preset in AIProviderPreset.all {
            #expect(AIProviderPreset.preset(withID: preset.id) == preset)
            #expect(preset.endpoint.hasPrefix("https://"), "\(preset.id) must default to https")
            #expect(AIEndpoint(preset.endpoint, style: .chatCompletions) != nil, "\(preset.id) endpoint must resolve")
        }
        #expect(AIProviderPreset.preset(withID: nil) == nil)
        #expect(AIProviderPreset.preset(withID: "no-such-vendor") == nil)
    }

    @Test("A provider added from a preset is a custom provider that reads as the vendor")
    func presetConfigReadsAsTheVendor() {
        let config = AIProviderConfig(preset: .requesty)
        #expect(config.type == .custom)
        #expect(config.presetID == "requesty")
        #expect(config.preset == .requesty)
        #expect(config.name == "Requesty")
        #expect(config.endpoint == "https://router.requesty.ai")
        #expect(config.kindName == "Requesty")
        #expect(config.symbolName == AIProviderPreset.requesty.symbolName)
        #expect(config.authStyle == .apiKey)
    }

    @Test("A preset provider whose name was cleared still shows the vendor, not Custom")
    func clearedNameFallsBackToTheVendor() {
        var config = AIProviderConfig(preset: .requesty)
        config.name = ""
        #expect(config.displayName == "Requesty")
    }

    @Test("A plain custom provider keeps its own name, icon and optional key")
    func plainCustomIsUnchanged() {
        let config = AIProviderConfig(type: .custom, endpoint: "https://api.z.ai/api/paas/v4")
        #expect(config.preset == nil)
        #expect(config.kindName == AIProviderType.custom.displayName)
        #expect(config.symbolName == AIProviderType.custom.symbolName)
        #expect(config.authStyle == .optionalApiKey)
        #expect(config.defaultEndpoint.isEmpty)
    }

    @Test("A preset id on a provider that is not custom changes nothing")
    func presetOnlyAppliesToCustom() {
        let config = AIProviderConfig(type: .openRouter, presetID: "requesty")
        #expect(config.preset == nil)
        #expect(config.endpoint == AIProviderType.openRouter.defaultEndpoint)
        #expect(config.kindName == "OpenRouter")
    }

    /// The point of a preset over a new provider type: the stored type is one every released
    /// build already decodes, so settings synced to an older build keep all their providers.
    @Test("A preset provider is stored under the custom type, which older builds decode")
    func storedTypeIsCustom() throws {
        let data = try JSONEncoder().encode(AIProviderConfig(preset: .requesty))
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        #expect(json["type"] as? String == "custom")
        #expect(json["presetID"] as? String == "requesty")
        #expect(json["name"] as? String == "Requesty")
        #expect(json["endpoint"] as? String == "https://router.requesty.ai")
    }

    @Test("A preset provider survives an encode and decode round trip")
    func roundTrips() throws {
        var config = AIProviderConfig(preset: .requesty)
        config.model = "anthropic/claude-sonnet-5"
        config.endpoint = "https://router.eu.requesty.ai"
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        #expect(decoded.authStyle == .apiKey)
    }

    @Test("A stored preset provider with no endpoint decodes to the preset's default")
    func emptyEndpointDecodesToThePresetDefault() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","type":"custom","presetID":"requesty","endpoint":""}"#
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: Data(json.utf8))
        #expect(decoded.endpoint == "https://router.requesty.ai")
    }

    @Test("A custom provider saved before presets existed decodes with none")
    func legacyCustomDecodes() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","type":"custom","name":"vLLM","endpoint":"http://gpu:8000"}"#
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: Data(json.utf8))
        #expect(decoded.presetID == nil)
        #expect(decoded.authStyle == .optionalApiKey)
        #expect(decoded.displayName == "vLLM")
    }

    /// A preset this build has never heard of comes from a newer build over sync. It has to keep
    /// working as the custom provider it is stored as, and keep its id for the build that knows it.
    @Test("A preset id this build does not know behaves as custom and is written back unchanged")
    func unknownPresetIsKept() throws {
        let json = #"""
        {"id":"11111111-2222-3333-4444-555555555555","type":"custom","presetID":"vendor-from-the-future",
         "name":"Future","endpoint":"https://api.future.example"}
        """#
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: Data(json.utf8))
        #expect(decoded.preset == nil)
        #expect(decoded.authStyle == .optionalApiKey)
        #expect(decoded.displayName == "Future")
        #expect(decoded.endpoint == "https://api.future.example")

        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(reencoded?["presetID"] as? String == "vendor-from-the-future")
    }

    @Test("A preset provider builds the OpenAI-compatible transport")
    func buildsTheSharedTransport() throws {
        let descriptor = try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.custom.rawValue))
        let config = AIProviderConfig(preset: .requesty)
        #expect(descriptor.makeProvider(config, "key") is OpenAICompatibleProvider)
        #expect(AIProviderFactory.makeUncachedProvider(for: config, apiKey: "key") is OpenAICompatibleProvider)
    }

    @Test("A preset that requires a key blocks the model list until one is typed")
    func modelListWaitsForTheKey() {
        let config = AIProviderConfig(preset: .requesty)
        #expect(
            AIModelListFetchGate.blocker(
                fetchesModelList: true, takesEndpoint: true,
                endpoint: config.endpoint, authStyle: config.authStyle, apiKey: ""
            ) == .missingAPIKey
        )
        #expect(
            AIModelListFetchGate.blocker(
                fetchesModelList: true, takesEndpoint: true,
                endpoint: config.endpoint, authStyle: config.authStyle, apiKey: "sk-live"
            ) == nil
        )
    }
}
