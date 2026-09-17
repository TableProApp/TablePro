//
//  ToolApprovalOrderingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ToolApprovalCenter ordering")
@MainActor
struct ToolApprovalOrderingTests {
    /// The defect: a turn drew a card for every proposed call at once but awaited them one at a
    /// time, so only the first had a continuation. Clicking Run on the second did nothing, in
    /// silence, while the stream stayed parked on the first.
    @Test("A decision made before its own await is honoured, not dropped")
    func earlyDecisionIsBuffered() async {
        let center = ToolApprovalCenter()
        center.expect(["first", "second"])

        center.resolve(toolUseId: "second", decision: .run)

        let first = Task { await center.awaitDecision(for: "first") }
        await Task.yield()
        center.resolve(toolUseId: "first", decision: .cancel)

        if case .cancel = await first.value {} else { Issue.record("first should cancel") }
        if case .run = await center.awaitDecision(for: "second") {} else { Issue.record("second should run") }
    }

    @Test("A decision nobody is waiting on is discarded")
    func unexpectedDecisionIsDiscarded() async {
        let center = ToolApprovalCenter()
        center.resolve(toolUseId: "stray", decision: .run)
        center.expect(["stray"])

        let waiter = Task { await center.awaitDecision(for: "stray") }
        await Task.yield()
        center.resolve(toolUseId: "stray", decision: .cancel)
        if case .cancel = await waiter.value {} else { Issue.record("the stray answer should not have survived") }
    }

    /// Several providers number every turn's calls from `call_0`, and a restored transcript still
    /// carries its pending cards, so an answer left lying around would be spent on a later write
    /// with no card shown for it.
    @Test("A turn's buffered answers do not outlive the turn")
    func forgettingDropsBufferedAnswers() async {
        let center = ToolApprovalCenter()
        center.expect(["call_0"])
        center.resolve(toolUseId: "call_0", decision: .run)
        center.forget(["call_0"])

        center.expect(["call_0"])
        let waiter = Task { await center.awaitDecision(for: "call_0") }
        await Task.yield()
        center.resolve(toolUseId: "call_0", decision: .cancel)
        if case .cancel = await waiter.value {} else {
            Issue.record("the previous turn's answer was spent on this one")
        }
    }

    /// A turn awaits its cards one at a time, so the later ones are announced but not awaited yet.
    /// Clearing them left the loop free to install a fresh continuation for the next card after the
    /// first resumed, and sit there for good.
    @Test("cancelAll answers a card the turn has not reached yet")
    func cancelAllAnswersUnreachedCards() async {
        let center = ToolApprovalCenter()
        center.expect(["first", "second"])

        let firstWaiter = Task { await center.awaitDecision(for: "first") }
        await Task.yield()
        center.cancelAll()

        if case .cancel = await firstWaiter.value {} else { Issue.record("first should cancel") }
        if case .cancel = await center.awaitDecision(for: "second") {} else {
            Issue.record("the second card would have hung")
        }
    }

    @Test("cancelAll clears buffered answers as well as waiters")
    func cancelAllClearsTheBuffer() async {
        let center = ToolApprovalCenter()
        center.expect(["pending"])
        center.resolve(toolUseId: "pending", decision: .run)
        center.cancelAll()
        center.forget(["pending"])

        center.expect(["pending"])
        let waiter = Task { await center.awaitDecision(for: "pending") }
        await Task.yield()
        center.resolve(toolUseId: "pending", decision: .cancel)
        if case .cancel = await waiter.value {} else { Issue.record("a cleared answer came back") }
    }
}
