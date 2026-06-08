//
//  CursorProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CursorProvider request encoding")
struct CursorProviderEncodingTests {
    @Test("Prompt renders the system prompt and the role-tagged conversation")
    func renderPrompt() {
        let options = ChatTransportOptions(model: "composer-2", systemPrompt: "You are a SQL helper.")
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text("List the users")]),
            ChatTurnWire(role: .assistant, blocks: [.text("SELECT * FROM users")]),
            ChatTurnWire(role: .user, blocks: [.text("Count them")])
        ]
        let prompt = CursorProvider.renderPrompt(turns: turns, options: options)
        #expect(prompt.contains("You are a SQL helper."))
        #expect(prompt.contains("User: List the users"))
        #expect(prompt.contains("Assistant: SELECT * FROM users"))
        #expect(prompt.contains("User: Count them"))
    }

    @Test("Launch body carries prompt text and model id")
    func launchBodyWithModel() {
        let body = CursorProvider.launchBody(prompt: "hello", model: "composer-2")
        let prompt = body["prompt"] as? [String: Any]
        #expect(prompt?["text"] as? String == "hello")
        let model = body["model"] as? [String: Any]
        #expect(model?["id"] as? String == "composer-2")
    }

    @Test("Launch body omits the model when none is selected")
    func launchBodyWithoutModel() {
        let body = CursorProvider.launchBody(prompt: "hi", model: "")
        #expect(body["model"] == nil)
        #expect((body["prompt"] as? [String: Any])?["text"] as? String == "hi")
    }
}
