//
//  ToolApprovalCenterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ToolApprovalCenter")
@MainActor
struct ToolApprovalCenterTests {
    private static let session = UUID()

    private static func request(_ toolUseId: String, session: UUID = ToolApprovalCenterTests.session) -> ApprovalRequestID {
        ApprovalRequestID(sessionId: session, toolUseId: toolUseId)
    }

    @Test("resolve delivers decision to awaiting caller")
    func resolveDelivers() async {
        let center = ToolApprovalCenter()
        let request = Self.request("tool-1")
        let waiter = Task {
            await center.awaitDecision(for: request)
        }
        await Task.yield()
        center.resolve(request, decision: .run)
        let decision = await waiter.value
        if case .run = decision {
            #expect(true)
        } else {
            Issue.record("expected .run, got \(decision)")
        }
    }

    @Test("resolve unknown id is a no-op")
    func resolveUnknown() {
        let center = ToolApprovalCenter()
        center.resolve(Self.request("missing"), decision: .cancel)
        #expect(center.hasPending == false)
    }

    @Test("cancelAll resolves every pending continuation as cancel")
    func cancelAllResolvesAll() async {
        let center = ToolApprovalCenter()
        let firstWaiter = Task { await center.awaitDecision(for: Self.request("a")) }
        let secondWaiter = Task { await center.awaitDecision(for: Self.request("b")) }
        await Task.yield()
        center.cancelAll()
        let firstDecision = await firstWaiter.value
        let secondDecision = await secondWaiter.value
        if case .cancel = firstDecision {} else { Issue.record("first should cancel") }
        if case .cancel = secondDecision {} else { Issue.record("second should cancel") }
        #expect(center.hasPending == false)
    }

    @Test("duplicate awaitDecision cancels the prior continuation")
    func duplicateAwaitCancelsPrior() async {
        let center = ToolApprovalCenter()
        let request = Self.request("tool-1")
        let firstWaiter = Task { await center.awaitDecision(for: request) }
        await Task.yield()
        let secondWaiter = Task { await center.awaitDecision(for: request) }
        await Task.yield()
        let firstDecision = await firstWaiter.value
        if case .cancel = firstDecision {} else {
            Issue.record("first should auto-cancel when overwritten, got \(firstDecision)")
        }
        center.resolve(request, decision: .alwaysAllow)
        let secondDecision = await secondWaiter.value
        if case .alwaysAllow = secondDecision {} else {
            Issue.record("second should resolve to alwaysAllow, got \(secondDecision)")
        }
    }

    @Test("hasPending reflects in-flight continuations")
    func hasPendingReflectsState() async {
        let center = ToolApprovalCenter()
        let request = Self.request("tool-1")
        #expect(center.hasPending == false)
        let waiter = Task { await center.awaitDecision(for: request) }
        await Task.yield()
        #expect(center.hasPending == true)
        center.resolve(request, decision: .run)
        _ = await waiter.value
        #expect(center.hasPending == false)
    }

    /// Several providers emit `call_0`, `call_1`, so this is the everyday case for two sessions
    /// streaming at once, not an exotic one. Keyed by the provider's string alone, the first
    /// session's continuation was resumed with `.cancel` the moment the second session asked.
    @Test("Two sessions holding the same provider tool-use id keep separate approvals")
    func identicalToolUseIdsDoNotCollide() async {
        let center = ToolApprovalCenter()
        let first = Self.request("call_0", session: UUID())
        let second = Self.request("call_0", session: UUID())

        let firstWaiter = Task { await center.awaitDecision(for: first) }
        let secondWaiter = Task { await center.awaitDecision(for: second) }
        await Task.yield()

        #expect(center.hasPending(sessionId: first.sessionId))
        #expect(center.hasPending(sessionId: second.sessionId))

        center.resolve(first, decision: .run)
        let firstDecision = await firstWaiter.value
        if case .run = firstDecision {} else { Issue.record("first should run, got \(firstDecision)") }

        #expect(center.hasPending(sessionId: second.sessionId), "second must still be waiting")
        #expect(!center.hasPending(sessionId: first.sessionId))

        center.resolve(second, decision: .cancel)
        let secondDecision = await secondWaiter.value
        if case .cancel = secondDecision {} else { Issue.record("second should cancel, got \(secondDecision)") }
    }

    /// Stop Generating in one session must not cancel the card another session is holding open.
    @Test("Cancelling one session leaves another session's approval pending")
    func sessionScopedCancelLeavesOthersAlone() async {
        let center = ToolApprovalCenter()
        let stopped = Self.request("call_0", session: UUID())
        let untouched = Self.request("call_0", session: UUID())

        let stoppedWaiter = Task { await center.awaitDecision(for: stopped) }
        let untouchedWaiter = Task { await center.awaitDecision(for: untouched) }
        await Task.yield()

        center.cancelAll(sessionId: stopped.sessionId)
        let stoppedDecision = await stoppedWaiter.value
        if case .cancel = stoppedDecision {} else { Issue.record("stopped session should cancel") }

        #expect(center.hasPending(sessionId: untouched.sessionId))

        center.resolve(untouched, decision: .run)
        let untouchedDecision = await untouchedWaiter.value
        if case .run = untouchedDecision {} else { Issue.record("untouched session should still run") }
    }

    @Test("Cancelling a session with nothing pending touches nothing")
    func sessionScopedCancelWithNothingPending() async {
        let center = ToolApprovalCenter()
        let held = Self.request("call_0", session: UUID())
        let waiter = Task { await center.awaitDecision(for: held) }
        await Task.yield()

        center.cancelAll(sessionId: UUID())

        #expect(center.hasPending(sessionId: held.sessionId))
        center.resolve(held, decision: .run)
        _ = await waiter.value
        #expect(center.hasPending == false)
    }
}
