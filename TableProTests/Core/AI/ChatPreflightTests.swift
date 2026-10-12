//
//  ChatPreflightTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ChatPreflightTests {
    private func text(_ length: Int) -> String {
        String(repeating: "a", count: length)
    }

    private func user(_ length: Int) -> ChatTurnWire {
        ChatTurnWire(role: .user, blocks: [.text(text(length))])
    }

    private func assistant(_ length: Int) -> ChatTurnWire {
        ChatTurnWire(role: .assistant, blocks: [.text(text(length))])
    }

    private func toolResults() -> ChatTurnWire {
        ChatTurnWire(role: .user, blocks: [.toolResult(ToolResultBlock(toolUseId: "call_0", content: "rows"))])
    }

    @Test("A request under the limit is sent")
    func fits() {
        let preflight = ChatPreflight(systemPrompt: text(10), turns: [user(10), assistant(10), user(10)], limit: 100)
        #expect(preflight.rejection == nil)
    }

    @Test("A request exactly at the limit is sent")
    func fitsAtTheLimit() {
        let preflight = ChatPreflight(systemPrompt: text(40), turns: [user(60)], limit: 100)
        #expect(preflight.rejection == nil)
    }

    @Test("A large system prompt is named when it outweighs the message")
    func systemPromptCause() {
        let preflight = ChatPreflight(systemPrompt: text(90), turns: [user(20)], limit: 100)
        #expect(preflight.rejection == .systemPrompt)
    }

    @Test("A long message is named when it outweighs the system prompt")
    func messageCause() {
        let preflight = ChatPreflight(systemPrompt: text(10), turns: [assistant(5), user(95)], limit: 100)
        #expect(preflight.rejection == .message)
    }

    @Test("History is named when the message and system prompt fit on their own")
    func historyCause() {
        let preflight = ChatPreflight(
            systemPrompt: text(10),
            turns: [user(45), assistant(45), user(10)],
            limit: 100
        )
        #expect(preflight.rejection == .history)
    }

    @Test("The message is every user turn after the last reply, and nothing earlier")
    func messageTurns() {
        let earlier = user(1)
        let reply = assistant(1)
        let invocation = user(2)
        let prompt = user(3)
        let preflight = ChatPreflight(systemPrompt: nil, turns: [earlier, reply, invocation, prompt], limit: 100)
        #expect(preflight.messageTurnIDs == [invocation.id, prompt.id])
        #expect(preflight.messageLength == 5)
        #expect(preflight.historyLength == 2)
    }

    @Test("Tool results are history, never a message to hand back")
    func toolResultsAreHistory() {
        let preflight = ChatPreflight(systemPrompt: text(10), turns: [user(50), assistant(40), toolResults()], limit: 60)
        #expect(preflight.messageTurnIDs.isEmpty)
        #expect(preflight.rejection == .history)
    }

    @Test("Length is counted in UTF-16 units, the way the limit is stated")
    func utf16Length() {
        let preflight = ChatPreflight(systemPrompt: "😀", turns: [], limit: 100)
        #expect(preflight.systemPromptLength == 2)
    }
}
