//
//  ToolApprovalCenterOrderingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ToolApprovalCenter ordering", .serialized)
struct ToolApprovalCenterOrderingTests {
    private func request(_ toolUseId: String, session: UUID) -> ApprovalRequestID {
        ApprovalRequestID(sessionId: session, toolUseId: toolUseId)
    }

    @Test("A decision made before the stream asks for it is honoured, not dropped")
    @MainActor
    func earlyDecisionIsHonoured() async {
        let center = ToolApprovalCenter()
        let session = UUID()
        let third = request("call_2", session: session)

        center.resolve(third, decision: .run)
        let decision = await center.awaitDecision(for: third)

        #expect(decision == .run)
        #expect(!center.hasPending(sessionId: session))
    }

    @Test("An early decision is consumed once")
    @MainActor
    func earlyDecisionIsConsumedOnce() async {
        let center = ToolApprovalCenter()
        let session = UUID()
        let target = request("call_0", session: session)

        center.resolve(target, decision: .run)
        _ = await center.awaitDecision(for: target)

        #expect(center.recordedDecision(for: target) == nil)
    }

    @Test("Three calls awaited together resolve in whatever order they are clicked")
    @MainActor
    func concurrentAwaitsResolveInClickOrder() async {
        let center = ToolApprovalCenter()
        let session = UUID()
        let ids = ["call_0", "call_1", "call_2"]
        let tasks = ids.map { id in
            (id, Task { @MainActor in await center.awaitDecision(for: request(id, session: session)) })
        }
        await Task.yield()

        center.resolve(request("call_2", session: session), decision: .run)
        center.resolve(request("call_0", session: session), decision: .cancel)
        center.resolve(request("call_1", session: session), decision: .run)

        var decisions: [String: ToolApprovalDecision] = [:]
        for (id, task) in tasks {
            decisions[id] = await task.value
        }

        #expect(decisions["call_0"] == .cancel)
        #expect(decisions["call_1"] == .run)
        #expect(decisions["call_2"] == .run)
    }

    @Test("A decision recorded for one session does not reach another")
    @MainActor
    func earlyDecisionsAreSessionScoped() async {
        let center = ToolApprovalCenter()
        let mine = UUID()
        let theirs = UUID()

        center.resolve(request("call_0", session: mine), decision: .run)

        #expect(center.recordedDecision(for: request("call_0", session: theirs)) == nil)
        #expect(center.recordedDecision(for: request("call_0", session: mine)) == .run)
    }

    @Test("Cancelling a session drops the decisions its stream never consumed")
    @MainActor
    func cancelDropsStrandedDecisions() {
        let center = ToolApprovalCenter()
        let mine = UUID()
        let theirs = UUID()
        center.resolve(request("call_0", session: mine), decision: .run)
        center.resolve(request("call_0", session: theirs), decision: .run)

        center.cancelAll(sessionId: mine)

        #expect(center.recordedDecision(for: request("call_0", session: mine)) == nil)
        #expect(center.recordedDecision(for: request("call_0", session: theirs)) == .run)
    }

    @Test("One session's pending requests are reported without the other's")
    @MainActor
    func pendingRequestsAreScoped() async {
        let center = ToolApprovalCenter()
        let mine = UUID()
        let theirs = UUID()
        let mineRequest = request("call_0", session: mine)
        let theirsRequest = request("call_0", session: theirs)
        let first = Task { @MainActor in await center.awaitDecision(for: mineRequest) }
        let second = Task { @MainActor in await center.awaitDecision(for: theirsRequest) }
        await Task.yield()

        #expect(center.pendingRequests(for: mine) == [mineRequest])
        #expect(center.pendingRequests(for: theirs) == [theirsRequest])

        center.cancelAll()
        _ = await first.value
        _ = await second.value
    }
}
