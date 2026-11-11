//
//  AIProviderModelFetchTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

private final class StubModelListProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var requestedURLs: [String] = []

    static func respond(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        Self.status = status
        Self.body = Data(body.utf8)
        requestedURLs = []
    }

    static func lastRequestedURL() -> String? {
        lock.lock(); defer { lock.unlock() }
        return requestedURLs.last
    }

    private static func record(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        requestedURLs.append(url)
    }

    private static func current() -> (status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        return (status, body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = Self.current()
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        Self.record(url.absoluteString)
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("AI provider model list", .serialized)
struct AIProviderModelFetchTests {
    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModelListProtocol.self]
        return URLSession(configuration: config)
    }

    /// The model list is the only live probe the settings sheet runs by itself, so answering a
    /// rejected request with a hardcoded list made a wrong Base URL look like a healthy provider.
    @Test("Claude reports a rejected model list instead of the offline one")
    func anthropicSurfacesHTTPFailure() async {
        StubModelListProtocol.respond(status: 404, body: #"{"error":{"message":"not found"}}"#)
        let provider = AnthropicProvider(
            endpoint: "https://api.anthropic.com",
            apiKey: "key",
            session: stubSession()
        )
        await #expect(throws: AIProviderError.self) {
            _ = try await provider.fetchAvailableModels()
        }
    }

    @Test("Gemini reports a rejected model list instead of the offline one")
    func geminiSurfacesHTTPFailure() async {
        StubModelListProtocol.respond(status: 401, body: #"{"error":{"message":"bad key"}}"#)
        let provider = GeminiProvider(
            endpoint: "https://generativelanguage.googleapis.com",
            apiKey: "key",
            session: stubSession()
        )
        await #expect(throws: AIProviderError.self) {
            _ = try await provider.fetchAvailableModels()
        }
    }

    @Test("Claude reaches the messages API under the base the user configured")
    func anthropicUsesTheResolvedBase() async throws {
        StubModelListProtocol.respond(status: 200, body: #"{"data":[{"id":"claude-opus-5"}]}"#)
        let provider = AnthropicProvider(
            endpoint: "https://api.anthropic.com/v1",
            apiKey: "key",
            session: stubSession()
        )
        _ = try await provider.fetchAvailableModels()
        #expect(StubModelListProtocol.lastRequestedURL() == "https://api.anthropic.com/v1/models")
    }

    @Test("OpenAI Responses reaches the model list under the base the user configured")
    func responsesUsesTheResolvedBase() async throws {
        StubModelListProtocol.respond(status: 200, body: #"{"data":[{"id":"gpt-5.5"}]}"#)
        let provider = OpenAIResponsesProvider(
            endpoint: "https://gateway.internal/openai/v2",
            apiKey: "key",
            session: stubSession()
        )
        _ = try await provider.fetchAvailableModels()
        #expect(StubModelListProtocol.lastRequestedURL() == "https://gateway.internal/openai/v2/models")
    }

    private func compatibleProvider(_ type: AIProviderType, endpoint: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            endpoint: endpoint,
            apiKey: "key",
            providerType: type,
            session: stubSession()
        )
    }

    @Test("An OpenAI-compatible server that serves no models answers with an empty list")
    func openAICompatibleEmptyListIsNotAnError() async throws {
        StubModelListProtocol.respond(status: 200, body: #"{"data":[]}"#)
        let models = try await compatibleProvider(.custom, endpoint: "https://host/v1").fetchAvailableModels()
        #expect(models.isEmpty)
    }

    @Test("An OpenAI-compatible model list comes back sorted by id, with what the server said about each model")
    func openAICompatibleListKeepsModelMetadata() async throws {
        StubModelListProtocol.respond(status: 200, body: #"""
        {"data":[
          {"id":"openai/gpt-5.5","supports_vision":true,"supports_reasoning":true},
          {"id":"alibaba/qwen-max","supports_vision":false,"supports_reasoning":false},
          {"object":"model"}
        ]}
        """#)
        let models = try await compatibleProvider(.custom, endpoint: "https://router.requesty.ai")
            .fetchAvailableModels()
        #expect(models.map(\.id) == ["alibaba/qwen-max", "openai/gpt-5.5"])
        #expect(models.first?.supportsImages == false)
        #expect(models.first?.reasoning == .unsupported)
        #expect(models.last?.supportsImages == true)
    }

    /// An empty picker with no error reads as "this server has no models", which is not what a
    /// gateway answering 200 with the wrong shape is saying.
    @Test("A 200 whose JSON has no model array is reported, not read as an empty list")
    func openAICompatibleWrongShapeThrows() async {
        StubModelListProtocol.respond(status: 200, body: #"{"models":[{"name":"a"}]}"#)
        await #expect(throws: AIProviderError.self) {
            _ = try await compatibleProvider(.custom, endpoint: "https://host/v1").fetchAvailableModels()
        }
    }

    @Test("A 200 that is not JSON at all is reported")
    func openAICompatibleNonJSONThrows() async {
        StubModelListProtocol.respond(status: 200, body: "<!doctype html><html></html>")
        await #expect(throws: AIProviderError.self) {
            _ = try await compatibleProvider(.custom, endpoint: "https://host/v1").fetchAvailableModels()
        }
    }

    @Test("An Ollama server with nothing pulled answers with an empty list")
    func ollamaEmptyListIsNotAnError() async throws {
        StubModelListProtocol.respond(status: 200, body: #"{"models":[]}"#)
        let models = try await compatibleProvider(.ollama, endpoint: "http://localhost:11434").fetchAvailableModels()
        #expect(models.isEmpty)
    }

    @Test("An Ollama route answering the wrong shape is reported")
    func ollamaWrongShapeThrows() async {
        StubModelListProtocol.respond(status: 200, body: #"{"data":[{"id":"a"}]}"#)
        await #expect(throws: AIProviderError.self) {
            _ = try await compatibleProvider(.ollama, endpoint: "http://localhost:11434").fetchAvailableModels()
        }
    }

    @Test("Gemini reaches the model list under the base the user configured")
    func geminiUsesTheResolvedBase() async throws {
        StubModelListProtocol.respond(status: 200, body: #"{"models":[]}"#)
        let provider = GeminiProvider(
            endpoint: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "key",
            session: stubSession()
        )
        _ = try await provider.fetchAvailableModels()
        #expect(
            StubModelListProtocol.lastRequestedURL()
                == "https://generativelanguage.googleapis.com/v1beta/models"
        )
    }

    /// OpenAI's list holds embedding, speech, image and realtime models beside the chat ones, and
    /// picking one in the chat panel failed the turn.
    @Test("OpenAI's own model list keeps only the models Responses can chat with")
    func openAIListKeepsChatModels() async throws {
        StubModelListProtocol.respond(status: 200, body: #"""
        {"object":"list","data":[
          {"id":"gpt-5.5","object":"model"},{"id":"text-embedding-3-small","object":"model"},
          {"id":"whisper-1","object":"model"},{"id":"gpt-image-1","object":"model"},
          {"id":"o3","object":"model"},{"id":"gpt-4o-realtime-preview","object":"model"},
          {"id":"tts-1","object":"model"},{"id":"omni-moderation-latest","object":"model"},
          {"id":"ft:gpt-4.1:acme::abc123","object":"model"}
        ]}
        """#)
        let provider = OpenAIResponsesProvider(endpoint: "https://api.openai.com", apiKey: "key", session: stubSession())
        let models = try await provider.fetchAvailableModels()
        #expect(models.map(\.id) == ["ft:gpt-4.1:acme::abc123", "gpt-5.5", "o3"])
    }

    @Test("A gateway in OpenAI's place keeps every model it lists")
    func gatewayListIsNotFiltered() async throws {
        StubModelListProtocol.respond(status: 200, body: #"{"data":[{"id":"text-embedding-3-small"},{"id":"gpt-5.5"}]}"#)
        let provider = OpenAIResponsesProvider(endpoint: "https://gateway.internal/openai", apiKey: "key", session: stubSession())
        let models = try await provider.fetchAvailableModels()
        #expect(models.map(\.id) == ["gpt-5.5", "text-embedding-3-small"])
    }

    @Test("xAI lists its chat models from language-models, with the images each one reads")
    func xaiListsLanguageModels() async throws {
        StubModelListProtocol.respond(status: 200, body: #"""
        {"models":[
          {"id":"grok-4.5","input_modalities":["text","image"],"output_modalities":["text"]},
          {"id":"grok-4.20-0309-non-reasoning","input_modalities":["text"],"output_modalities":["text"]},
          {"id":"grok-imagine-image","input_modalities":["text","image"],"output_modalities":["image"]}
        ]}
        """#)
        let provider = OpenAIResponsesProvider(
            endpoint: "https://api.x.ai", apiKey: "key", dialect: .xai, session: stubSession()
        )
        let models = try await provider.fetchAvailableModels()
        #expect(StubModelListProtocol.lastRequestedURL() == "https://api.x.ai/v1/language-models")
        #expect(models.map(\.id) == ["grok-4.20-0309-non-reasoning", "grok-4.5"])
        #expect(models.first?.supportsImages == false)
        #expect(models.last?.supportsImages == true)
    }

    @Test("Without language-models, an xAI list drops image, video and voice models by what it says")
    func xaiFallbackDropsNonChatModels() {
        let keep: [[String: Any]] = [["id": "grok-4.5"], ["id": "grok-4.3"]]
        let drop: [[String: Any]] = [
            ["id": "grok-studio-1", "image_price": 200],
            ["id": "grok-imagine-video-1.5"],
            ["id": "grok-voice-3.0"]
        ]
        for entry in keep {
            #expect(OpenAIResponsesProvider.listsChatModel(entry, dialect: .xai, host: "api.x.ai"))
        }
        for entry in drop {
            #expect(!OpenAIResponsesProvider.listsChatModel(entry, dialect: .xai, host: "api.x.ai"))
        }
    }

    @Test("OpenAI's regional hosts are filtered like its main one; a fine-tune is judged by its base model")
    func openAIRegionalHostAndFineTunes() {
        let whisper: [String: Any] = ["id": "whisper-1"]
        #expect(!OpenAIResponsesProvider.listsChatModel(whisper, dialect: .openAI, host: "eu.api.openai.com"))
        #expect(OpenAIResponsesProvider.listsChatModel(whisper, dialect: .openAI, host: "gateway.internal"))
        #expect(OpenAIResponsesProvider.isOpenAIChatModel("ft:gpt-4o-mini-2024-07-18:watts-energy::AbC123"))
        #expect(OpenAIResponsesProvider.isOpenAIChatModel("ft:gpt-4.1:acme:doc-search:x1"))
        #expect(!OpenAIResponsesProvider.isOpenAIChatModel("ft:whisper-1:acme::x2"))
    }

    @Test("Without a usable language-models answer, xAI's list comes from its model list minus image models")
    func xaiFallsBackToTheModelList() async throws {
        RoutedModelListProtocol.routes = [
            "/v1/language-models": (200, #"{"models":[{"id":"grok-only-listed-here","input_modalities":["text"]}]}"#),
            "/v1/models": (200, #"{"data":[{"id":"grok-4.5"},{"id":"grok-2-image-1212"},{"id":"grok-imagine-image","image_price":200}]}"#)
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutedModelListProtocol.self]
        let provider = OpenAIResponsesProvider(
            endpoint: "https://api.x.ai", apiKey: "key", dialect: .xai, session: URLSession(configuration: config)
        )
        #expect(try await provider.fetchAvailableModels().map(\.id) == ["grok-4.5"])

        RoutedModelListProtocol.routes["/v1/language-models"] = (404, "")
        #expect(try await provider.fetchAvailableModels().map(\.id) == ["grok-4.5"])
    }
}

private final class RoutedModelListProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let route = Self.routes[url.path] ?? (404, "")
        guard let response = HTTPURLResponse(
            url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
