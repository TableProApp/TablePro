//
//  ChatGPTCodexProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatGPTCodexProvider request encoding")
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

    @Test("Available models returns the curated subscription list without a network call")
    func curatedModels() async throws {
        let provider = ChatGPTCodexProvider(model: "")
        let models = try await provider.fetchAvailableModels()
        #expect(models == ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"])
    }
}
