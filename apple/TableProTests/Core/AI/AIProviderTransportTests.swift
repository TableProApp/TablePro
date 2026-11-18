//
//  AIProviderTransportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIProviderTransportTests {
    private func transport(headers: [String: String]) -> AIProviderTransport {
        AIProviderTransport(
            endpoint: " https://host.example ",
            style: .chatCompletions,
            headers: headers,
            session: URLSession(configuration: .ephemeral)
        )
    }

    @Test("A bearer header goes out only for a key that is not empty")
    func bearerNeedsAKey() {
        #expect(AIProviderTransport.bearer("sk-1") == ["Authorization": "Bearer sk-1"])
        #expect(AIProviderTransport.bearer("").isEmpty)
        #expect(AIProviderTransport.bearer(nil).isEmpty)
    }

    @Test("A POST carries JSON, the configured headers and the body")
    func postShape() throws {
        let transport = transport(headers: ["Authorization": "Bearer k", "anthropic-version": "2023-06-01"])
        let request = try transport.post(try transport.url("chat/completions"), body: ["model": "m"])
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://host.example/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "m")
    }

    @Test("A model-list GET carries the headers and the short timeout; an unauthenticated one carries none")
    func getShape() throws {
        let transport = transport(headers: ["Authorization": "Bearer k"])
        let url = try transport.url("models")
        let request = transport.get(url)
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == AIProvider.modelListTimeout)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(transport.get(url, authenticated: false).value(forHTTPHeaderField: "Authorization") == nil)
        #expect(transport.get(url, timeout: nil).timeoutInterval == URLRequest(url: url).timeoutInterval)
    }

    @Test("An endpoint that does not resolve reports what the user typed, trimmed")
    func invalidEndpoint() {
        let transport = AIProviderTransport(
            endpoint: " api.example.com/v1 ",
            style: .chatCompletions,
            headers: [:],
            session: URLSession(configuration: .ephemeral)
        )
        let error = #expect(throws: AIProviderError.self) { _ = try transport.url("models") }
        guard case .invalidEndpoint(let endpoint)? = error else {
            Issue.record("expected invalidEndpoint; got \(String(describing: error))")
            return
        }
        #expect(endpoint == "api.example.com/v1")
    }

    @Test("Claude sends its key header and API version; OpenAI-compatible sends a bearer only with a key")
    func providerHeaders() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let options = ChatTransportOptions(model: "m")

        let claude = try AnthropicProvider(endpoint: "https://api.anthropic.com", apiKey: " sk-ant ")
            .buildMessagesRequest(turns: [turn], options: options, effort: nil)
        #expect(claude.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(claude.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(claude.value(forHTTPHeaderField: "Authorization") == nil)

        let keyed = try OpenAICompatibleProvider(endpoint: "https://host/v1", apiKey: " sk-1 ", providerType: .custom)
            .buildChatCompletionRequest(turns: [turn], options: options)
        #expect(keyed.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(keyed.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let keyless = try OpenAICompatibleProvider(endpoint: "http://localhost:11434", apiKey: nil, providerType: .ollama)
            .buildChatCompletionRequest(turns: [turn], options: options)
        #expect(keyless.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
