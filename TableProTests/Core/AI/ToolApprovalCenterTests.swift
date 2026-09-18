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
    private let session = UUID()

    @Test("resolve delivers decision to awaiting caller")
    func resolveDelivers() async {
        let center = ToolApprovalCenter()
        let waiter = Task {
            await center.awaitDecision(sessionId: session, toolUseId: "tool-1")
        }
        await Task.yield()
        center.resolve(sessionId: session, toolUseId: "tool-1", decision: .run)
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
        center.resolve(sessionId: session, toolUseId: "missing", decision: .cancel)
        #expect(center.hasPending == false)
    }

    @Test("cancelAll resolves every pending continuation of that session as cancel")
    func cancelAllResolvesAll() async {
        let center = ToolApprovalCenter()
        let firstWaiter = Task { await center.awaitDecision(sessionId: session, toolUseId: "a") }
        let secondWaiter = Task { await center.awaitDecision(sessionId: session, toolUseId: "b") }
        await Task.yield()
        center.cancelAll(sessionId: session)
        let firstDecision = await firstWaiter.value
        let secondDecision = await secondWaiter.value
        if case .cancel = firstDecision {} else { Issue.record("first should cancel") }
        if case .cancel = secondDecision {} else { Issue.record("second should cancel") }
        #expect(center.hasPending == false)
    }

    @Test("duplicate awaitDecision cancels the prior continuation")
    func duplicateAwaitCancelsPrior() async {
        let center = ToolApprovalCenter()
        let firstWaiter = Task { await center.awaitDecision(sessionId: session, toolUseId: "tool-1") }
        await Task.yield()
        let secondWaiter = Task { await center.awaitDecision(sessionId: session, toolUseId: "tool-1") }
        await Task.yield()
        let firstDecision = await firstWaiter.value
        if case .cancel = firstDecision {} else {
            Issue.record("first should auto-cancel when overwritten, got \(firstDecision)")
        }
        center.resolve(sessionId: session, toolUseId: "tool-1", decision: .alwaysAllow)
        let secondDecision = await secondWaiter.value
        if case .alwaysAllow = secondDecision {} else {
            Issue.record("second should resolve to alwaysAllow, got \(secondDecision)")
        }
    }

    @Test("hasPending reflects in-flight continuations")
    func hasPendingReflectsState() async {
        let center = ToolApprovalCenter()
        #expect(center.hasPending == false)
        let waiter = Task { await center.awaitDecision(sessionId: session, toolUseId: "tool-1") }
        await Task.yield()
        #expect(center.hasPending == true)
        center.resolve(sessionId: session, toolUseId: "tool-1", decision: .run)
        _ = await waiter.value
        #expect(center.hasPending == false)
    }

    /// Several endpoints number every turn's calls from `call_0`, so two sessions streaming at once
    /// can both be waiting on `call_0`. Keyed by the id alone, one session's click answered the
    /// other's statement.
    @Test("One session's answer never reaches another session's call")
    func decisionsDoNotCrossSessions() async {
        let center = ToolApprovalCenter()
        let other = UUID()
        let mine = Task { await center.awaitDecision(sessionId: session, toolUseId: "call_0") }
        let theirs = Task { await center.awaitDecision(sessionId: other, toolUseId: "call_0") }
        await Task.yield()

        center.resolve(sessionId: session, toolUseId: "call_0", decision: .run)
        if case .run = await mine.value {} else { Issue.record("this session's answer went missing") }

        center.resolve(sessionId: other, toolUseId: "call_0", decision: .cancel)
        if case .cancel = await theirs.value {} else { Issue.record("the other session took this one's answer") }
    }

    /// One session stopping used to cancel every other session's pending approvals, which is the
    /// whole reason several sessions could not run at once.
    @Test("Stopping one session leaves another session's call waiting")
    func cancelAllIsScopedToItsSession() async {
        let center = ToolApprovalCenter()
        let other = UUID()
        let survivor = Task { await center.awaitDecision(sessionId: other, toolUseId: "call_0") }
        let victim = Task { await center.awaitDecision(sessionId: session, toolUseId: "call_0") }
        await Task.yield()

        center.cancelAll(sessionId: session)
        if case .cancel = await victim.value {} else { Issue.record("the stopped session should cancel") }
        #expect(center.hasPending(sessionId: other))

        center.resolve(sessionId: other, toolUseId: "call_0", decision: .run)
        if case .run = await survivor.value {} else { Issue.record("the other session was cancelled with it") }
    }

    @Test("cancelEverything answers every session")
    func cancelEverythingAnswersEverySession() async {
        let center = ToolApprovalCenter()
        let other = UUID()
        let mine = Task { await center.awaitDecision(sessionId: session, toolUseId: "call_0") }
        let theirs = Task { await center.awaitDecision(sessionId: other, toolUseId: "call_0") }
        await Task.yield()

        center.cancelEverything()

        if case .cancel = await mine.value {} else { Issue.record("first should cancel") }
        if case .cancel = await theirs.value {} else { Issue.record("second should cancel") }
        #expect(center.hasPending == false)
    }
}
