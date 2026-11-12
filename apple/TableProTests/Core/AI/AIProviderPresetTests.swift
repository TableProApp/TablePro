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
        #expect(config.icon == AIProviderPreset.requesty.icon)
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
        #expect(config.icon == AIProviderType.custom.icon)
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

    @Test("Meta needs a key, reads a 401 as a bad key, and resolves to its chat completions route")
    func metaPreset() {
        let preset = AIProviderPreset.meta
        #expect(preset.authStyle == .apiKey)
        #expect(!preset.rejectsBadKeyWithForbidden)

        let config = AIProviderConfig(preset: preset)
        let style = config.type.endpointStyle
        #expect(config.kindName == "Meta")
        #expect(
            AIEndpoint(config.endpoint, style: style)?.chatURL(model: "muse-spark-1.3", style: style)?.absoluteString
                == "https://api.meta.ai/v1/chat/completions"
        )
        #expect(
            AIEndpoint(config.endpoint, style: style)?.url(appending: style.modelsResource)?.absoluteString
                == "https://api.meta.ai/v1/models"
        )
    }

    @Test("A new Meta provider starts on Muse Spark 1.3 before its model list loads")
    func metaStartsOnMuseSpark() throws {
        let descriptor = try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.custom.rawValue))
        let curated = descriptor.curatedModels(for: AIProviderPreset.meta)
        #expect(curated.map(\.id) == ["muse-spark-1.3", "muse-wonder-1.0", "muse-ember-1.0"])
        #expect(AIProviderDraftRules.initialModel(curated: curated, fetched: []) == "muse-spark-1.3")
        #expect(descriptor.curatedModels(for: AIProviderPreset.requesty).isEmpty)
        #expect(descriptor.curatedModels(for: nil).isEmpty)
    }

    /// Meta may train on what a contributor model is sent, so a list click never picks one.
    @Test("Meta lists only its chat models, without the contributor ones; a preset with no filter lists every model")
    func metaListsChatModels() {
        let listed = ["muse-image-1.0", "muse-spark-1.3", "muse-spark-1.2-contributor", "muse-voice-transcribe-1.0",
                      "sam-3.1", "muse-ember-1.0", "muse-wonder-1.0"]
        #expect(listed.filter { AIProviderPreset.meta.modelIDs.lists($0) }
            == ["muse-spark-1.3", "muse-ember-1.0", "muse-wonder-1.0"])
        #expect(AIProviderPreset.meta.modelIDs.isChatFamily("muse-spark-1.2-contributor"))
        #expect(listed.allSatisfy { AIProviderPreset.requesty.modelIDs.lists($0) })
    }

    @Test("A contributor model stays out of Meta's list wherever its id carries the word")
    func contributorModelsStayUnlisted() {
        for id in ["muse-spark-1.4-contributor-preview", "muse-spark-1.3-contributor"] {
            #expect(!AIProviderPreset.meta.modelIDs.lists(id), "\(id)")
        }
    }

    @Test("Meta's model filter applies on Meta's host only; a gateway keeps its whole list")
    func metaFilterFollowsTheHost() {
        #expect(AIProviderPreset.meta.modelIDFilter(forEndpoint: "https://api.meta.ai") == AIProviderPreset.meta.modelIDs)
        #expect(AIProviderPreset.meta.modelIDFilter(forEndpoint: " https://API.meta.ai/v1 ") == AIProviderPreset.meta.modelIDs)
        #expect(AIProviderPreset.meta.modelIDFilter(forEndpoint: "https://gateway.example/meta") == .all)
    }

    @Test("Every Meta chat model always reasons, from minimal to extra high, starting at high")
    func metaReasoningIsMandatory() throws {
        let descriptor = try #require(AIProviderRegistry.shared.descriptor(for: AIProviderType.custom.rawValue))
        for model in ["muse-spark-1.3", "muse-spark-1.1", "muse-wonder-1.0", "muse-ember-1.0"] {
            let reasoning = descriptor.reasoning(forModelID: model, fetched: AIModelInfo(id: model), preset: .meta)
            #expect(reasoning.isMandatory, "\(model)")
            #expect(reasoning.effortLevels == [.minimal, .low, .medium, .high, .xhigh], "\(model)")
            #expect(reasoning.defaultEffort == .high, "\(model)")
        }
        let typed = descriptor.reasoning(forModelID: "llama-4", preset: .meta)
        #expect(!typed.isMandatory)
        #expect(typed.effortLevels == [.low, .medium, .high])
        #expect(!descriptor.reasoning(forModelID: "muse-spark-1.3").isMandatory)
    }

    @Test("A Meta provider asks the server only for chat models")
    func metaModelListIsFiltered() async throws {
        MetaModelListProtocol.body = #"""
        {"object":"list","data":[
          {"id":"muse-image-1.0","object":"model","created":1788000003,"owned_by":"meta"},
          {"id":"muse-spark-1.3","object":"model","created":1788000002,"owned_by":"meta"},
          {"id":"sam-3.1","object":"model","created":1788000001,"owned_by":"meta"},
          {"id":"muse-voice-transcribe-1.0","object":"model","created":1788000000,"owned_by":"meta"},
          {"id":"muse-spark-1.3-contributor","object":"model","created":1787000001,"owned_by":"meta"},
          {"id":"muse-ember-1.0","object":"model","created":1787000000,"owned_by":"meta"}
        ]}
        """#
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MetaModelListProtocol.self]
        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(preset: .meta),
            apiKey: "LLM_1_key",
            session: URLSession(configuration: sessionConfig)
        )
        let models = try await provider.fetchAvailableModels()
        #expect(models.map(\.id) == ["muse-ember-1.0", "muse-spark-1.3"])
    }
}

private final class MetaModelListProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
