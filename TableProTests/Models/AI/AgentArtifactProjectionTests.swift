//
//  AgentArtifactProjectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct AgentArtifactProjectionTests {
    private func toolUse(id: String, query: String, approval: ToolApprovalState = .approved) -> ChatContentBlock {
        .toolUse(ToolUseBlock(
            id: id,
            name: "execute_query",
            input: .object(["query": .string(query)]),
            approvalState: approval
        ))
    }

    private func toolResult(id: String, content: String, isError: Bool = false) -> ChatContentBlock {
        .toolResult(ToolResultBlock(toolUseId: id, content: content, isError: isError))
    }

    /// Several endpoints number every turn's calls from `call_0`, so a fifth round reuses the ids of
    /// the first. Matching across the whole transcript gave every earlier call the last round's
    /// outcome.
    @Test("A reused tool-use id takes its own round's result")
    func reusedIdsMatchWithinTheirRound() {
        let turns = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 1")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: #"{"rows":[]}"#)]),
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 2")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: "boom", isError: true)]),
        ]

        let artifact = AgentArtifactProjection.build(from: turns)

        #expect(artifact.statements.count == 2)
        #expect(artifact.statements[0].sql == "SELECT 1")
        #expect(artifact.statements[0].state == .ran)
        #expect(artifact.statements[1].sql == "SELECT 2")
        #expect(artifact.statements[1].state == .failed(reason: "boom"))
    }

    @Test("Two statements sharing a provider id get distinct row identities")
    func reusedIdsProduceDistinctRows() {
        let turns = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 1")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: "{}")]),
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 2")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: "{}")]),
        ]

        let artifact = AgentArtifactProjection.build(from: turns)

        #expect(Set(artifact.statements.map(\.id)).count == 2)
        #expect(Set(artifact.runs.map(\.id)).count == 2)
    }

    @Test("A rejected call keeps its own state whatever result follows")
    func rejectedCallIgnoresItsResult() {
        let turns = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "DROP TABLE t", approval: .cancelled)]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: "User cancelled this tool call.", isError: true)]),
        ]

        let artifact = AgentArtifactProjection.build(from: turns)

        #expect(artifact.statements.count == 1)
        #expect(artifact.statements[0].state == .rejected)
        #expect(artifact.runs.isEmpty)
    }

    /// The Copilot path records its result in the same turn as the call, because Copilot keeps the
    /// conversation server-side and never asks for the result back.
    @Test("A result in the calling turn is matched too")
    func resultInTheSameTurnMatches() {
        let turns = [
            ChatTurn(role: .assistant, blocks: [
                toolUse(id: "tool-1", query: "SELECT 3"),
                toolResult(id: "tool-1", content: #"{"rows":[]}"#),
            ]),
        ]

        let artifact = AgentArtifactProjection.build(from: turns)

        #expect(artifact.statements.count == 1)
        #expect(artifact.statements[0].state == .ran)
        #expect(artifact.runs.count == 1)
    }

    @Test("A call still waiting reads as waiting")
    func pendingCallReadsAsWaiting() {
        let turns = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "DELETE FROM t", approval: .pending)]),
        ]

        let artifact = AgentArtifactProjection.build(from: turns)

        #expect(artifact.statements[0].state == .waiting)
    }
}
