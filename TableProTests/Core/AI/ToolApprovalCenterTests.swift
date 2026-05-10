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
    @Test("resolve delivers decision to awaiting caller")
    func resolveDelivers() async {
        let center = ToolApprovalCenter()
        let waiter = Task {
            await center.awaitDecision(for: "tool-1")
        }
        await Task.yield()
        center.resolve(toolUseId: "tool-1", decision: .run)
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
        center.resolve(toolUseId: "missing", decision: .cancel)
        #expect(center.hasPending == false)
    }

    @Test("cancelAll resolves every pending continuation as cancel")
    func cancelAllResolvesAll() async {
        let center = ToolApprovalCenter()
        let firstWaiter = Task { await center.awaitDecision(for: "a") }
        let secondWaiter = Task { await center.awaitDecision(for: "b") }
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
        let firstWaiter = Task { await center.awaitDecision(for: "tool-1") }
        await Task.yield()
        let secondWaiter = Task { await center.awaitDecision(for: "tool-1") }
        await Task.yield()
        let firstDecision = await firstWaiter.value
        if case .cancel = firstDecision {} else {
            Issue.record("first should auto-cancel when overwritten, got \(firstDecision)")
        }
        center.resolve(toolUseId: "tool-1", decision: .alwaysAllow)
        let secondDecision = await secondWaiter.value
        if case .alwaysAllow = secondDecision {} else {
            Issue.record("second should resolve to alwaysAllow, got \(secondDecision)")
        }
    }

    @Test("hasPending reflects in-flight continuations")
    func hasPendingReflectsState() async {
        let center = ToolApprovalCenter()
        #expect(center.hasPending == false)
        let waiter = Task { await center.awaitDecision(for: "tool-1") }
        await Task.yield()
        #expect(center.hasPending == true)
        center.resolve(toolUseId: "tool-1", decision: .run)
        _ = await waiter.value
        #expect(center.hasPending == false)
    }
}
