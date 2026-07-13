//
//  XAIGrokProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("XAIGrokProvider request encoding")
struct XAIGrokProviderEncodingTests {
    @Test("Requests carry the Grok CLI identity headers and the model override")
    func requestHeaders() {
        let headers = XAIGrokProvider.requestHeaders(accessToken: "tok", model: "grok-build")
        #expect(headers["Authorization"] == "Bearer tok")
        #expect(headers["X-XAI-Token-Auth"] == "xai-grok-cli")
        #expect(headers["x-grok-client-version"] == "0.2.93")
        #expect(headers["x-grok-model-override"] == "grok-build")
        #expect(headers["Content-Type"] == "application/json")
    }

    @Test("An empty model omits the override header")
    func emptyModelOmitsOverride() {
        let headers = XAIGrokProvider.requestHeaders(accessToken: "tok", model: "")
        #expect(headers["x-grok-model-override"] == nil)
    }

    @Test("The body sends only the effort that the proxy accepts, without summary or include")
    func reasoningBodyShape() throws {
        let options = ChatTransportOptions(model: "grok-4.5", reasoningEffort: .high)
        let turn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let body = try XAIGrokProvider.requestBody(turns: [turn], options: options, stream: true)

        #expect(body["model"] as? String == "grok-4.5")
        #expect(body["stream"] as? Bool == true)
        let reasoning = body["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "high")
        #expect(reasoning?["summary"] == nil)
        #expect(body["include"] == nil)
    }

    @Test("An out-of-range effort is clamped into the accepted low/medium/high set")
    func effortClamped() throws {
        let options = ChatTransportOptions(model: "grok-4.5", reasoningEffort: .xhigh)
        let turn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let body = try XAIGrokProvider.requestBody(turns: [turn], options: options, stream: false)
        let reasoning = body["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "high")
    }

    @Test("No reasoning effort means no reasoning key")
    func noReasoning() throws {
        let options = ChatTransportOptions(model: "grok-4.5")
        let turn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let body = try XAIGrokProvider.requestBody(turns: [turn], options: options, stream: false)
        #expect(body["reasoning"] == nil)
    }

    @Test("fetchAvailableModels returns the subscription catalog without a network call")
    func subscriptionModels() async throws {
        let provider = XAIGrokProvider(model: "grok-build")
        let models = try await provider.fetchAvailableModels()
        #expect(models == ["grok-4.5", "grok-build", "grok-composer-2.5-fast"])
    }
}
