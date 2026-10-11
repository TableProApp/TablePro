//
//  AgentArtifactCacheTests.swift
//  TableProTests
//
//  The result column projected the whole transcript and decoded the selected run's JSON from
//  computed properties read in `body`, which `AgentResultDecoder`'s own header forbids: a reply
//  streaming into the turn redraws the pane again and again, and each redraw did both once more.
//  These cases pin what a rebuild costs and what it is keyed on.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct AgentArtifactCacheTests {
    /// Counting in a class rather than a captured `var`, because a `@MainActor` closure is `Sendable`
    /// and cannot hold one.
    @MainActor
    private final class Tally {
        var projections = 0
        var decodes = 0
    }

    private func makeCache(_ tally: Tally) -> AgentArtifactCache {
        AgentArtifactCache(
            project: { turns in
                tally.projections += 1
                return AgentArtifactProjection.build(from: turns)
            },
            decode: { json in
                tally.decodes += 1
                return AgentResultDecoder.payload(fromResultJSON: json)
            }
        )
    }

    private func makeSession(id: UUID = UUID()) -> AgentSession {
        AgentSession(
            id: id,
            connectionId: UUID(),
            viewModel: AIChatViewModel(services: .live, sessionId: id, restoringConversation: nil)
        )
    }

    private func toolUse(id: String, query: String, approval: ToolApprovalState = .approved) -> ChatContentBlock {
        .toolUse(ToolUseBlock(
            id: id,
            name: "execute_query",
            input: .object(["query": .string(query)]),
            approvalState: approval
        ))
    }

    private func toolResult(id: String, content: String) -> ChatContentBlock {
        .toolResult(ToolResultBlock(toolUseId: id, content: content, isError: false))
    }

    @Test("Text streaming into the open turn does not project the transcript again")
    func streamingDoesNotReproject() {
        let tally = Tally()
        let cache = makeCache(tally)
        let session = makeSession()
        let reply = ChatTurn(role: .assistant, blocks: [])
        session.viewModel.messages = [ChatTurn(role: .user, blocks: [.text("Which orders shipped late?")]), reply]

        _ = cache.artifact(for: session)
        for chunk in ["Look", "ing at", " orders"] {
            reply.appendStreamingToken(chunk)
            _ = cache.artifact(for: session)
        }

        #expect(tally.projections == 1, "A streaming reply rebuilt the projection \(tally.projections) times")
    }

    /// A call waiting for an answer lands in the turn that is still open, so a key of finished turns
    /// would keep it off the column until some later turn arrived.
    @Test("A call proposed inside the open turn projects once")
    func aProposedCallRebuildsOnce() {
        let tally = Tally()
        let cache = makeCache(tally)
        let session = makeSession()
        let reply = ChatTurn(role: .assistant, blocks: [])
        session.viewModel.messages = [reply]
        _ = cache.artifact(for: session)

        reply.appendBlock(toolUse(id: "call_0", query: "SELECT 1", approval: .pending))

        #expect(cache.artifact(for: session).statements.map(\.sql) == ["SELECT 1"])
        #expect(cache.artifact(for: session).statements.count == 1)
        #expect(tally.projections == 2)
    }

    /// Answering the call changes the statement's state, and the state is in the key.
    @Test("Approving a call projects again")
    func approvalRebuilds() throws {
        let tally = Tally()
        let cache = makeCache(tally)
        let session = makeSession()
        let block = toolUse(id: "call_0", query: "DELETE FROM t", approval: .pending)
        session.viewModel.messages = [ChatTurn(role: .assistant, blocks: [block])]
        #expect(cache.artifact(for: session).statements.first?.state == .waiting)

        guard case .toolUse(var use) = block.kind else {
            Issue.record("The block stopped being a call")
            return
        }
        use.approvalState = .cancelled
        block.setKind(.toolUse(use))

        #expect(cache.artifact(for: session).statements.first?.state == .rejected)
        #expect(tally.projections == 2)
    }

    /// Copilot records a result in the turn that made the call, so the turn count never moves for it.
    @Test("A result in the calling turn projects again")
    func resultInTheSameTurnRebuilds() {
        let tally = Tally()
        let cache = makeCache(tally)
        let session = makeSession()
        let reply = ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 1")])
        session.viewModel.messages = [reply]
        #expect(cache.artifact(for: session).runs.isEmpty)

        reply.appendBlock(toolResult(id: "call_0", content: #"{"columns":["n"],"rows":[[1]]}"#))

        #expect(cache.artifact(for: session).runs.count == 1)
        #expect(tally.projections == 2)
    }

    /// Two conversations can agree on every provider call id, so the key names blocks by their own.
    @Test("A different session projects again and keeps nothing of the first")
    func switchingSessionRebuilds() {
        let tally = Tally()
        let cache = makeCache(tally)
        let first = makeSession()
        let second = makeSession()
        let payload = #"{"columns":["n"],"rows":[[1]]}"#
        first.viewModel.messages = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 1")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: payload)]),
        ]
        second.viewModel.messages = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 2")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: payload)]),
        ]

        let firstRuns = cache.artifact(for: first).runs
        let secondRuns = cache.artifact(for: second).runs

        #expect(firstRuns.map(\.sql) == ["SELECT 1"])
        #expect(secondRuns.map(\.sql) == ["SELECT 2"])
        #expect(tally.projections == 2)
    }

    @Test("A run is decoded once however often the column draws it")
    func decodesEachRunOnce() throws {
        let tally = Tally()
        let cache = makeCache(tally)
        let session = makeSession()
        session.viewModel.messages = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 1")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: #"{"columns":["n"],"rows":[[1]]}"#)]),
        ]
        let run = try #require(cache.artifact(for: session).runs.first)

        for _ in 0 ..< 5 {
            guard case .rows(let rows) = cache.payload(for: run) else {
                Issue.record("The run decoded to something other than rows")
                return
            }
            #expect(rows.count == 1)
        }

        #expect(tally.decodes == 1)
    }

    /// The transcript is the only copy of a result, so a decode is worth keeping only while the run
    /// it belongs to is still in the projection.
    @Test("A run that leaves the transcript takes its decoded result with it")
    func prunesDecodedRunsThatAreGone() throws {
        let tally = Tally()
        let cache = makeCache(tally)
        let session = makeSession()
        let payload = #"{"columns":["n"],"rows":[[1]]}"#
        session.viewModel.messages = [
            ChatTurn(role: .assistant, blocks: [toolUse(id: "call_0", query: "SELECT 1")]),
            ChatTurn(role: .user, blocks: [toolResult(id: "call_0", content: payload)]),
        ]
        let run = try #require(cache.artifact(for: session).runs.first)
        _ = cache.payload(for: run)

        session.viewModel.messages = []
        _ = cache.artifact(for: session)
        _ = cache.payload(for: run)

        #expect(tally.decodes == 2)
    }
}
