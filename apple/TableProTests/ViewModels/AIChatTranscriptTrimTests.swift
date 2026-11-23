//
//  AIChatTranscriptTrimTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

@MainActor
struct AIChatTranscriptTrimTests {
    private func call(_ id: String) -> ChatContentBlockWire {
        .toolUse(ToolUseBlock(id: id, name: "describe_table", input: .object([:])))
    }

    private func result(_ id: String) -> ChatContentBlockWire {
        .toolResult(ToolResultBlock(toolUseId: id, content: "ok"))
    }

    private func calls(in turn: ChatTurnWire) -> Set<String> {
        Set(turn.blocks.compactMap { block -> String? in
            guard case .toolUse(let use) = block.kind else { return nil }
            return use.id
        })
    }

    private func results(in turn: ChatTurnWire) -> [String] {
        turn.blocks.compactMap { block -> String? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result.toolUseId
        }
    }

    // Every result answers a call in the turn right before it, which is what providers accept.
    private func everyResultHasItsCall(_ turns: [ChatTurnWire]) -> Bool {
        turns.indices.allSatisfy { index in
            let answered = results(in: turns[index])
            guard !answered.isEmpty else { return true }
            guard index > 0, turns[index - 1].role == .assistant else { return false }
            return Set(answered).isSubset(of: calls(in: turns[index - 1]))
        }
    }

    // Exchanges of a question, a tool round and an answer, then the question being sent: 201 turns.
    private func toolTranscript() -> [ChatTurnWire] {
        var turns: [ChatTurnWire] = []
        for exchange in 0..<50 {
            turns.append(ChatTurnWire(role: .user, blocks: [.text("question \(exchange)")]))
            turns.append(ChatTurnWire(role: .assistant, blocks: [call("call_\(exchange)")]))
            turns.append(ChatTurnWire(role: .user, blocks: [result("call_\(exchange)")]))
            turns.append(ChatTurnWire(role: .assistant, blocks: [.text("answer \(exchange)")]))
        }
        turns.append(ChatTurnWire(role: .user, blocks: [.text("and now?")]))
        return turns
    }

    @Test("A trimmed tool transcript starts at a question, never at a result whose call was cut")
    func trimStartsAtARound() {
        let viewModel = AIChatViewModel()
        viewModel.messages = toolTranscript().map { ChatTurn(wire: $0) }

        viewModel.trimMessagesIfNeeded()

        let wire = viewModel.messages.map { $0.wireSnapshot }
        let opening = wire.first?.blocks.first.flatMap { block -> String? in
            guard case .text(let text) = block.kind else { return nil }
            return text
        }
        #expect(wire.count <= AIChatViewModel.maxMessageCount)
        #expect(wire.first?.role == .user)
        #expect(opening == "question 1")
        #expect(everyResultHasItsCall(wire))
        #expect(ChatToolCallRepair.answeringEveryToolCall(wire) == wire)
    }

    @Test("A transcript cut short on disk drops a leading result whose call is gone and keeps its text")
    func repairDropsALeadingOrphan() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [result("call_gone"), .text("also, count rows")]),
            ChatTurnWire(role: .assistant, blocks: [.text("12")]),
            ChatTurnWire(role: .user, blocks: [.text("thanks")])
        ]

        let repaired = ChatToolCallRepair.answeringEveryToolCall(turns)

        #expect(repaired.count == 3)
        #expect(results(in: repaired[0]).isEmpty)
        #expect(repaired[0].blocks.count == 1)
        #expect(everyResultHasItsCall(repaired))
    }

    @Test("A turn that held only orphan results is dropped, and a result for another round's call goes")
    func repairDropsOrphanTurnsAndStrayResults() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [result("call_gone")]),
            ChatTurnWire(role: .assistant, blocks: [.text("done")]),
            ChatTurnWire(role: .user, blocks: [.text("count users")]),
            ChatTurnWire(role: .assistant, blocks: [call("a")]),
            ChatTurnWire(role: .user, blocks: [result("a"), result("call_gone")])
        ]

        let repaired = ChatToolCallRepair.answeringEveryToolCall(turns)

        #expect(repaired.count == 4)
        #expect(repaired.first?.role == .assistant)
        #expect(results(in: repaired[3]) == ["a"])
        #expect(everyResultHasItsCall(repaired))
    }
}
