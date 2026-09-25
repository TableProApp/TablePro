//
//  TabExecutionRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TabExecutionRegistryTests {
    @Test("A fresh claim is current")
    func freshClaimIsCurrent() {
        var registry = TabExecutionRegistry()
        let claim = registry.claim(UUID())
        #expect(registry.isCurrent(claim))
    }

    @Test("Claiming the same tab again invalidates the previous claim")
    func reclaimingInvalidatesPredecessor() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let first = registry.claim(tabId)
        let second = registry.claim(tabId)

        #expect(registry.isCurrent(first) == false)
        #expect(registry.isCurrent(second))
    }

    /// The exact case the per-window generation counter could not represent: the user navigated
    /// away and the successor never started, so nothing ever bumped the counter and the in-flight
    /// result stayed "current" all the way into the grid.
    @Test("Invalidating with no successor still kills the in-flight claim")
    func invalidateWithoutSuccessorKillsClaim() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)

        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isCurrent(claim) == false)
        #expect(registry.isExecuting(tabId) == false)
    }

    @Test("Claims on different tabs do not invalidate each other")
    func claimsAreScopedPerTab() {
        var registry = TabExecutionRegistry()
        let tabA = UUID()
        let tabB = UUID()
        let claimA = registry.claim(tabA)
        let claimB = registry.claim(tabB)

        _ = registry.invalidate(tabB, reason: .supersededNavigation)

        #expect(registry.isCurrent(claimA))
        #expect(registry.isCurrent(claimB) == false)
    }

    @Test("Busy state is derived from membership, not stored")
    func busyStateIsDerived() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        #expect(registry.isExecuting(tabId) == false)

        let claim = registry.claim(tabId)
        #expect(registry.isExecuting(tabId))
        #expect(registry.isAnyExecuting)

        let settled = registry.settle(claim)
        #expect(settled)
        #expect(registry.isExecuting(tabId) == false)
        #expect(registry.isAnyExecuting == false)
    }

    /// A late result must not clear the busy state of the navigation that superseded it, or the
    /// window reports idle while a query is still running.
    @Test("A stale claim settles nothing")
    func staleClaimCannotSettle() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let stale = registry.claim(tabId)
        let live = registry.claim(tabId)

        let settledStale = registry.settle(stale)
        #expect(settledStale == false)

        #expect(registry.isExecuting(tabId))
        #expect(registry.isCurrent(live))
    }

    /// The whole point of the return value. A completing execution has one question, "may I write
    /// this?", and settling has to answer it, because asking `isCurrent` afterwards is always false
    /// and asking it beforehand is a separate call someone will eventually put in the wrong order.
    /// That is what silently swallowed every query error in 0.64.0 (#2120).
    @Test("Settling answers whether the claim owned the tab")
    func settleReportsOwnership() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)

        let firstSettle = registry.settle(claim)
        #expect(firstSettle)
        let secondSettle = registry.settle(claim)
        #expect(secondSettle == false)

        let superseded = registry.claim(tabId)
        _ = registry.invalidate(tabId, reason: .supersededNavigation)
        let settledSuperseded = registry.settle(superseded)
        #expect(settledSuperseded == false)
    }

    /// Work that outlives its own claim, phase 2 and clearing pending edits, asks about content
    /// instead. Content identity is what survives the settle and dies on a retarget.
    @Test("Content ownership survives a settle but not a retarget or a reclaim")
    func ownsContentOutlivesTheClaim() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)

        let settled = registry.settle(claim)
        #expect(settled)
        #expect(registry.ownsContent(claim))

        _ = registry.invalidate(tabId, reason: .supersededNavigation)
        #expect(registry.ownsContent(claim) == false)

        let reclaimed = registry.claim(tabId)
        _ = registry.claim(tabId)
        #expect(registry.ownsContent(reclaimed) == false)
    }

    @Test("An unknown tab is idle")
    func unknownTabIsIdle() {
        let registry = TabExecutionRegistry()
        let tabId = UUID()
        #expect(registry.isExecuting(tabId) == false)
        #expect(registry.isAnyExecuting == false)
    }

    @Test("Teardown invalidates every tab at once")
    func invalidateAllClearsEveryTab() {
        var registry = TabExecutionRegistry()
        let claimA = registry.claim(UUID())
        let claimB = registry.claim(UUID())

        _ = registry.invalidateAll(reason: .sessionEnded)

        #expect(registry.isCurrent(claimA) == false)
        #expect(registry.isCurrent(claimB) == false)
        #expect(registry.isAnyExecuting == false)
    }


    /// Fetch All extends the result already on screen, so it validates against the content epoch and
    /// cannot claim the tab without discarding its own rows. The window still has to call it busy.
    @Test("Unclaimed work makes the window busy without claiming the tab")
    func unclaimedWorkCountsAsBusy() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let epochBefore = registry.contentEpoch(for: tabId)

        let token = registry.beginUnclaimedWork(for: tabId)

        #expect(registry.isAnyExecuting)
        #expect(registry.isExecuting(tabId) == false)
        #expect(registry.contentEpoch(for: tabId) == epochBefore)

        registry.endUnclaimedWork(token, for: tabId)
        #expect(registry.isAnyExecuting == false)
    }

    @Test("Two pieces of unclaimed work on one tab end independently")
    func unclaimedWorkTokensAreIndependent() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let first = registry.beginUnclaimedWork(for: tabId)
        let second = registry.beginUnclaimedWork(for: tabId)

        registry.endUnclaimedWork(first, for: tabId)
        #expect(registry.isAnyExecuting)

        registry.endUnclaimedWork(second, for: tabId)
        #expect(registry.isAnyExecuting == false)
    }

    /// Work unwinding after Stop must not put the window back to busy.
    @Test("Ending a token the registry has already released is a no-op")
    func endingAReleasedTokenIsANoOp() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let token = registry.beginUnclaimedWork(for: tabId)

        _ = registry.invalidateAll(reason: .cancelledByUser)
        #expect(registry.isAnyExecuting == false)

        registry.endUnclaimedWork(token, for: tabId)
        #expect(registry.isAnyExecuting == false)
    }

    @Test("Retargeting a tab releases its unclaimed work with its claim")
    func invalidateReleasesUnclaimedWork() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        _ = registry.claim(tabId)
        _ = registry.beginUnclaimedWork(for: tabId)

        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isAnyExecuting == false)
    }

    /// The window's chrome reads `isAnyExecuting`, so every way an execution can end has to leave it
    /// false. A stored second copy of this answer is what kept the titlebar busy after the work was
    /// over, recoverable only by pressing Stop (#2342).
    @Test("Every way an execution ends leaves the window idle")
    func everyEndingLeavesTheWindowIdle() {
        for reason: ExecutionEndReason in [.cancelledByUser, .supersededNavigation, .sessionEnded, .abandoned] {
            var registry = TabExecutionRegistry()
            let tabId = UUID()
            _ = registry.claim(tabId)
            #expect(registry.isAnyExecuting)

            _ = registry.invalidate(tabId, reason: reason)
            #expect(registry.isAnyExecuting == false)
        }

        var settling = TabExecutionRegistry()
        let claim = settling.claim(UUID())
        let settled = settling.settle(claim)
        #expect(settled)
        #expect(settling.isAnyExecuting == false)
    }

    /// Epochs are window-global so two tabs never share one, which keeps a claim comparable on its
    /// own without also carrying the tab's mutable identity fields.
    @Test("Epochs are unique across tabs")
    func epochsAreUniqueAcrossTabs() {
        var registry = TabExecutionRegistry()
        let claimA = registry.claim(UUID())
        let claimB = registry.claim(UUID())
        #expect(claimA.epoch != claimB.epoch)
    }

    // MARK: - The uninterruptible phase

    @Test("A stale claim cannot enter the uninterruptible phase")
    func staleClaimCannotMarkTheTab() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let first = registry.claim(tabId)
        _ = registry.claim(tabId)

        let markedStale = registry.enterUninterruptiblePhase(first)
        #expect(markedStale == false)
        #expect(registry.isStoppable(tabId))
    }

    /// The whole point. Stop lands while the commit is on the wire, the claim survives it, and the
    /// settle that follows still answers yes, so the batch's results reach the tab.
    @Test("Stop keeps a claim that is committing, and it still settles afterwards")
    func stopKeepsACommittingClaim() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let contentEpoch = registry.contentEpoch(for: tabId)
        let marked = registry.enterUninterruptiblePhase(claim)
        #expect(marked)

        let outcome = registry.stop(tabId)

        #expect(outcome.ended.isEmpty)
        #expect(outcome.keptUninterruptibleClaim)
        #expect(registry.isExecuting(tabId))
        #expect(registry.isCurrent(claim))
        #expect(registry.contentEpoch(for: tabId) == contentEpoch)
        #expect(registry.isStoppable(tabId) == false)

        let settled = registry.settle(claim)
        #expect(settled)
        #expect(registry.isAnyExecuting == false)
    }

    @Test("Stop ends the tab's own claim, bumps its content epoch, and leaves every other tab")
    func stopEndsOnlyTheNamedTab() {
        var registry = TabExecutionRegistry()
        let other = UUID()
        let stopped = UUID()
        let otherClaim = registry.claim(other)
        let stoppedClaim = registry.claim(stopped)
        let stoppedEpoch = registry.contentEpoch(for: stopped)
        let otherEpoch = registry.contentEpoch(for: other)

        let outcome = registry.stop(stopped)

        #expect(outcome.ended.map(\.tabId) == [stopped])
        #expect(outcome.ended.first?.reason == .cancelledByUser)
        #expect(registry.isCurrent(stoppedClaim) == false)
        #expect(registry.contentEpoch(for: stopped) != stoppedEpoch)
        #expect(registry.isCurrent(otherClaim))
        #expect(registry.contentEpoch(for: other) == otherEpoch)
    }

    @Test("Stop keeps a committing claim on its own tab")
    func stopKeepsTheMarkedClaim() {
        var registry = TabExecutionRegistry()
        let committing = UUID()
        let committingClaim = registry.claim(committing)
        let marked = registry.enterUninterruptiblePhase(committingClaim)
        #expect(marked)

        let outcome = registry.stop(committing)

        #expect(outcome.ended.isEmpty)
        #expect(outcome.keptUninterruptibleClaim)
        #expect(registry.isCurrent(committingClaim))
    }

    @Test("Stop ends unclaimed work even on a tab that is committing")
    func stopEndsUnclaimedWork() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        _ = registry.beginUnclaimedWork(for: tabId)
        let marked = registry.enterUninterruptiblePhase(claim)
        #expect(marked)

        _ = registry.stop(tabId)

        #expect(registry.isBusy(tabId))
        #expect(registry.isStoppable(tabId) == false)
    }

    /// Only Stop reads the mark. Closing the tab, a retarget and a lost session all end the claim
    /// whatever it is doing, because the window it belongs to is going away regardless.
    @Test(
        "Everything other than Stop ends a committing claim",
        arguments: [ExecutionEndReason.abandoned, .sessionEnded, .supersededNavigation, .cancelledByUser]
    )
    func invalidationIgnoresTheMark(reason: ExecutionEndReason) {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let marked = registry.enterUninterruptiblePhase(claim)
        #expect(marked)

        let ended = registry.invalidate(tabId, reason: reason)

        #expect(ended?.reason == reason)
        #expect(registry.isExecuting(tabId) == false)

        var all = TabExecutionRegistry()
        let allClaim = all.claim(UUID())
        let markedAll = all.enterUninterruptiblePhase(allClaim)
        #expect(markedAll)
        let endedAll = all.invalidateAll(reason: reason)
        #expect(endedAll.count == 1)
        #expect(all.isAnyExecuting == false)
    }

    /// A script that commits half way through goes on running, so Stop has to come back.
    @Test("Leaving the phase makes the claim stoppable again")
    func leavingThePhaseRestoresStop() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let marked = registry.enterUninterruptiblePhase(claim)
        #expect(marked)
        registry.leaveUninterruptiblePhase(claim)

        #expect(registry.isStoppable(tabId))
        let outcome = registry.stop(tabId)
        #expect(outcome.ended.map(\.tabId) == [tabId])
        #expect(!outcome.keptUninterruptibleClaim)
        #expect(registry.isExecuting(tabId) == false)
    }

    @Test("A stale claim cannot unmark the tab it no longer owns")
    func staleClaimCannotLeaveThePhase() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let stale = registry.claim(tabId)
        let current = registry.claim(tabId)
        let marked = registry.enterUninterruptiblePhase(current)
        #expect(marked)

        registry.leaveUninterruptiblePhase(stale)

        #expect(registry.isStoppable(tabId) == false)
    }

    @Test("An idle tab is not stoppable and unclaimed work is")
    func stoppabilityFollowsWhatIsRunning() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        #expect(registry.isStoppable(tabId) == false)

        let token = registry.beginUnclaimedWork(for: tabId)
        #expect(registry.isStoppable(tabId))

        registry.endUnclaimedWork(token, for: tabId)
        #expect(registry.isStoppable(tabId) == false)
    }
}
