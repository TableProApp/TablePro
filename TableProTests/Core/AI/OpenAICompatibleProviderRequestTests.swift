//
//  OpenAICompatibleProviderRequestTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct OpenAICompatibleProviderRequestTests {
    private func requestBody(
        type: AIProviderType = .custom,
        effort: ReasoningEffort? = nil,
        maxOutputTokens: Int? = nil,
        providerID: UUID? = nil,
        catalog: AIModelCatalog = AIModelCatalog()
    ) throws -> [String: Any] {
        let provider = OpenAICompatibleProvider(
            endpoint: type == .ollama ? "http://localhost:11434" : "https://host/v1",
            apiKey: "key",
            providerType: type,
            model: "m",
            maxOutputTokens: maxOutputTokens,
            providerID: providerID,
            catalog: catalog
        )
        let request = try provider.buildChatCompletionRequest(
            turns: [ChatTurnWire(role: .user, blocks: [.text("hi")])],
            options: ChatTransportOptions(model: "m", reasoningEffort: effort)
        )
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    /// The reported defect: the sheet offered Off, Low, Medium and High for every model on an
    /// OpenAI-compatible provider, and the request was the same whichever was picked.
    @Test("A chosen reasoning effort is sent as reasoning_effort")
    func effortIsSent() throws {
        #expect(try requestBody(effort: .high)["reasoning_effort"] as? String == "high")
        #expect(try requestBody(type: .openRouter, effort: .low)["reasoning_effort"] as? String == "low")
    }

    @Test("With reasoning off, the request carries no effort")
    func noEffortWhenOff() throws {
        #expect(try requestBody(effort: nil)["reasoning_effort"] == nil)
    }

    @Test("The effort is withheld from a model its server lists as non-reasoning")
    func effortWithheldFromANonReasoningModel() throws {
        let catalog = AIModelCatalog()
        let provider = UUID()
        catalog.store(providerID: provider, models: [AIModelInfo(id: "m", reasoning: .unsupported)])
        let body = try requestBody(effort: .high, providerID: provider, catalog: catalog)
        #expect(body["reasoning_effort"] == nil)
    }

    @Test("The effort is sent to a model its server lists as reasoning, or says nothing about")
    func effortSentWhenSupportedOrUnstated() throws {
        let catalog = AIModelCatalog()
        let reasoning = UUID()
        catalog.store(providerID: reasoning, models: [
            AIModelInfo(id: "m", reasoning: AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high]))
        ])
        #expect(
            try requestBody(effort: .medium, providerID: reasoning, catalog: catalog)["reasoning_effort"] as? String
                == "medium"
        )

        let silent = UUID()
        catalog.store(providerID: silent, models: [AIModelInfo(id: "m")])
        #expect(
            try requestBody(effort: .medium, providerID: silent, catalog: catalog)["reasoning_effort"] as? String
                == "medium"
        )
    }

    @Test("An OpenAI-compatible server gets max_tokens and usage in the stream")
    func chatCompletionsLimits() throws {
        let body = try requestBody(maxOutputTokens: 512)
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["options"] == nil)
        #expect(body["stream_options"] != nil)
    }

    /// Ollama's native route ignores a top-level max_tokens, so the Max output tokens field did
    /// nothing there.
    @Test("Ollama gets its output limit as options.num_predict, and no OpenAI-only fields")
    func ollamaLimits() throws {
        let body = try requestBody(type: .ollama, effort: .high, maxOutputTokens: 512)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 512)
        #expect(body["max_tokens"] == nil)
        #expect(body["stream_options"] == nil)
        #expect(body["reasoning_effort"] == nil)
    }

    private func imageTurn(_ source: ChatImageInput.Source, text: String) -> ChatTurnWire {
        ChatTurnWire(role: .user, blocks: [.text(text), .image(ChatImageInput(source: source))])
    }

    /// Ollama's native route takes a string content and base64 images beside it. The OpenAI
    /// content-part array is not a string, so it rejected every message that carried an image.
    @Test("Ollama gets an attached image as base64 beside a string content")
    func ollamaImageShape() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let filename = AIImageCache.shared.store(data: bytes, mediaType: "image/png")
        defer { AIImageCache.shared.delete(filename: filename) }

        let provider = OpenAICompatibleProvider(endpoint: "http://localhost:11434", apiKey: nil, providerType: .ollama)
        let messages = provider.encodeTurn(
            imageTurn(.cacheFile(filename: filename, mediaType: "image/png"), text: "what is this")
        )
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "what is this")
        #expect(messages[0]["images"] as? [String] == [bytes.base64EncodedString()])
    }

    @Test("Ollama keeps the text of a turn whose image has no bytes to send")
    func ollamaRemoteImageKeepsTheText() throws {
        let url = try #require(URL(string: "https://example.com/a.png"))
        let provider = OpenAICompatibleProvider(endpoint: "http://localhost:11434", apiKey: nil, providerType: .ollama)
        let messages = provider.encodeTurn(imageTurn(.remoteURL(url, mediaType: "image/png"), text: "what is this"))
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "what is this")
        #expect(messages[0]["images"] == nil)
    }

    @Test("An OpenAI-compatible server still gets an image as an image_url content part")
    func chatCompletionsImageShape() throws {
        let url = try #require(URL(string: "https://example.com/a.png"))
        let provider = OpenAICompatibleProvider(endpoint: "https://host/v1", apiKey: "key", providerType: .custom)
        let messages = provider.encodeTurn(imageTurn(.remoteURL(url, mediaType: "image/png"), text: "what is this"))
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
    }
}
