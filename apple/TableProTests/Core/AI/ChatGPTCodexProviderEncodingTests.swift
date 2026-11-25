//
//  ChatGPTCodexProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ChatGPTCodexProviderEncodingTests {
    @Test("Headers carry bearer token, account id, and Codex originator")
    func headersIncludeAccountAndOriginator() {
        let headers = ChatGPTCodexProvider.requestHeaders(
            accessToken: "tok-123",
            accountID: "acct-9",
            sessionID: "sess-1"
        )
        #expect(headers["Authorization"] == "Bearer tok-123")
        #expect(headers["ChatGPT-Account-ID"] == "acct-9")
        #expect(headers["session-id"] == "sess-1")
        #expect(headers["originator"] == "codex_cli_rs")
        #expect(headers["User-Agent"] == ChatGPTCodex.userAgent)
    }

    @Test("Empty account id omits the ChatGPT-Account-ID header")
    func emptyAccountOmitsHeader() {
        let headers = ChatGPTCodexProvider.requestHeaders(
            accessToken: "tok",
            accountID: "",
            sessionID: "sess"
        )
        #expect(headers["ChatGPT-Account-ID"] == nil)
    }

    @Test("Body sends store=false, stream flag, and the system prompt as instructions")
    func bodyUsesSystemPrompt() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("hi")])
        let options = ChatTransportOptions(model: "gpt-5.5", systemPrompt: "schema context")
        let body = try ChatGPTCodexProvider.requestBody(turns: [turn], options: options, stream: true)
        #expect(body["model"] as? String == "gpt-5.5")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "schema context")
        #expect(body["input"] != nil)
    }

    @Test("Body omits max_output_tokens, which the Codex backend rejects")
    func bodyOmitsMaxOutputTokens() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("hi")])
        let options = ChatTransportOptions(model: "gpt-5.5", maxOutputTokens: 4_096)
        let body = try ChatGPTCodexProvider.requestBody(turns: [turn], options: options, stream: true)
        #expect(body["max_output_tokens"] == nil)
    }

    @Test("Body falls back to default instructions when no system prompt is set")
    func bodyDefaultInstructions() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("hi")])
        let options = ChatTransportOptions(model: "gpt-5.5")
        let body = try ChatGPTCodexProvider.requestBody(turns: [turn], options: options, stream: false)
        #expect(body["instructions"] as? String == ChatGPTCodexProvider.defaultInstructions)
        #expect(body["stream"] as? Bool == false)
    }

    // Shaped like the backend's reply, measured 2026-11-24: hidden entries are internal, priority ranks the list.
    @Test("The backend's model list is ranked by priority, hidden models dropped, the first one the default")
    func backendModelList() throws {
        let reply: [String: Any] = ["models": [
            ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list", "priority": 5,
             "default_reasoning_level": "low",
             "supported_reasoning_levels": [["effort": "low"], ["effort": "medium"], ["effort": "max"], ["effort": "ultra"]],
             "input_modalities": ["text", "image"]],
            ["slug": "gpt-reserve", "visibility": "hide", "priority": 4],
            ["slug": "gpt-6.2-sol", "display_name": "GPT-6.2-Sol", "visibility": "list", "priority": 1,
             "supported_reasoning_levels": [["effort": "low"], ["effort": "high"]]]
        ]]
        let models = ChatGPTCodexProvider.decodeModelList(try JSONSerialization.data(withJSONObject: reply))
        #expect(models.map(\.id) == ["gpt-6.2-sol", "gpt-6.1-sol"])
        #expect(models.first?.isProviderDefault == true)
        #expect(models.last?.isProviderDefault == false)
        let reasoning = try #require(models.last?.reasoning)
        #expect(reasoning.effortLevels == [.low, .medium, .max])
        #expect(reasoning.defaultEffort == .low)
        #expect(reasoning.isMandatory)
        #expect(models.last?.displayName == "GPT-6.1-Sol")
    }
}
