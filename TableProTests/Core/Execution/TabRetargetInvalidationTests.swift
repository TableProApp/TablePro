//
//  TabRetargetInvalidationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Pins the confirmed race: clicking table B while table A's query is in flight used to block B's
/// query entirely and then paint A's rows into the tab that had already become B.
@Suite("Tab retarget invalidates in-flight execution")
struct TabRetargetInvalidationTests {
    @Test("A result that started before the retarget is not current after it")
    func retargetInvalidatesInFlightResult() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()

        let tableA = registry.claim(tabId)

        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isCurrent(tableA) == false)
    }

    /// Step 3 of the confirmed chain. The old stored bool stayed true through the retarget, so the
    /// second table's query was refused and never ran at all.
    @Test("The retargeted tab is free to execute immediately")
    func retargetedTabIsNotBusy() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()

        let tableA = registry.claim(tabId)
        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isExecuting(tabId) == false)

        let tableB = registry.claim(tabId)
        #expect(registry.isCurrent(tableB))
        #expect(registry.isCurrent(tableA) == false)
    }

    /// Step 4. The old counter only moved when a successor execution started, so a retarget whose
    /// successor was refused left the in-flight result looking perfectly current.
    @Test("Invalidation holds even when no successor execution ever starts")
    func invalidationHoldsWithoutSuccessor() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let tableA = registry.claim(tabId)

        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isCurrent(tableA) == false)
        #expect(registry.isExecuting(tabId) == false)
    }

    @Test("The superseding execution survives its predecessor's late completion")
    func lateCompletionCannotDisturbSuccessor() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()

        let tableA = registry.claim(tabId)
        _ = registry.invalidate(tabId, reason: .supersededNavigation)
        let tableB = registry.claim(tabId)

        let settled = registry.settle(tableA)
        #expect(settled == false)

        #expect(registry.isCurrent(tableB))
        #expect(registry.isExecuting(tabId))
    }

    /// Background work that augments an applied result has no claim of its own, so it captures the
    /// tab's content identity instead. A retarget must invalidate that too.
    @Test("Content identity changes on retarget so background work cannot write back")
    func retargetChangesContentIdentity() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let settled = registry.settle(claim)
        #expect(settled)

        let captured = registry.contentEpoch(for: tabId)
        #expect(registry.isSameContent(captured, for: tabId))

        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isSameContent(captured, for: tabId) == false)
    }

    @Test("Content identity survives a settled claim so a row count can still apply")
    func contentIdentitySurvivesSettle() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let captured = registry.contentEpoch(for: tabId)

        let settled = registry.settle(claim)
        #expect(settled)

        #expect(registry.isSameContent(captured, for: tabId))
    }

    @Test("Cancelling every query invalidates every tab's content identity")
    func cancelAllInvalidatesEveryTab() {
        var registry = TabExecutionRegistry()
        let tabA = UUID()
        let tabB = UUID()
        _ = registry.claim(tabA)
        _ = registry.claim(tabB)
        let capturedA = registry.contentEpoch(for: tabA)
        let capturedB = registry.contentEpoch(for: tabB)

        _ = registry.invalidateAll(reason: .cancelledByUser)

        #expect(registry.isSameContent(capturedA, for: tabA) == false)
        #expect(registry.isSameContent(capturedB, for: tabB) == false)
        #expect(registry.isAnyExecuting == false)
    }

}

@Suite("DriverCancellationPolicy")
struct DriverCancellationPolicyTests {
    @Test("Only untracked leases stay invisible to cancellation")
    func trackingReflectsPolicy() {
        #expect(DriverCancellationPolicy.untracked.isTracked == false)
        #expect(DriverCancellationPolicy.cancellableRead.isTracked)
        #expect(DriverCancellationPolicy.protectedWrite.isTracked)
    }

    /// A commit or a DDL statement is registered so the connection reads as busy, but aborting one
    /// half way is data loss, so it must never be a cancellation target.
    @Test("A protected write is tracked but is not a cancellation target")
    func protectedWriteIsTrackedButNotCancellable() {
        let policy = DriverCancellationPolicy.protectedWrite
        #expect(policy.isTracked)
        #expect(policy != .cancellableRead)
    }
}
