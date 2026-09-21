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
}
