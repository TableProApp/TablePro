//
//  TabExecutionRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TabExecutionRegistry")
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


    /// Epochs are window-global so two tabs never share one, which keeps a claim comparable on its
    /// own without also carrying the tab's mutable identity fields.
    @Test("Epochs are unique across tabs")
    func epochsAreUniqueAcrossTabs() {
        var registry = TabExecutionRegistry()
        let claimA = registry.claim(UUID())
        let claimB = registry.claim(UUID())
        #expect(claimA.epoch != claimB.epoch)
    }
}
