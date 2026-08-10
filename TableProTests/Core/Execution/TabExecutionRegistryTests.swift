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

        registry.invalidate(tabId)

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

        registry.invalidate(tabB)

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

        registry.settle(claim)
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

        registry.settle(stale)

        #expect(registry.isExecuting(tabId))
        #expect(registry.isCurrent(live))
    }

    @Test("A stale claim cannot advance the phase")
    func staleClaimCannotAdvancePhase() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let stale = registry.claim(tabId)
        _ = registry.claim(tabId)

        registry.advance(stale, to: .applying)

        #expect(registry.phase(for: tabId) == .preparing)
    }

    @Test("The current claim advances through its phases")
    func currentClaimAdvancesPhases() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        #expect(registry.phase(for: tabId) == .preparing)

        registry.advance(claim, to: .executing)
        #expect(registry.phase(for: tabId) == .executing)

        registry.advance(claim, to: .applying)
        #expect(registry.phase(for: tabId) == .applying)
    }

    @Test("An unknown tab has no phase and is not executing")
    func unknownTabIsIdle() {
        let registry = TabExecutionRegistry()
        let tabId = UUID()
        #expect(registry.phase(for: tabId) == nil)
        #expect(registry.isExecuting(tabId) == false)
        #expect(registry.executingTabIds.isEmpty)
    }

    @Test("Teardown invalidates every tab at once")
    func invalidateAllClearsEveryTab() {
        var registry = TabExecutionRegistry()
        let claimA = registry.claim(UUID())
        let claimB = registry.claim(UUID())

        registry.invalidateAll()

        #expect(registry.isCurrent(claimA) == false)
        #expect(registry.isCurrent(claimB) == false)
        #expect(registry.isAnyExecuting == false)
    }

    @Test("Executing tab ids report every live claim")
    func reportsExecutingTabIds() {
        var registry = TabExecutionRegistry()
        let tabA = UUID()
        let tabB = UUID()
        let claimA = registry.claim(tabA)
        _ = registry.claim(tabB)

        #expect(registry.executingTabIds == [tabA, tabB])

        registry.settle(claimA)
        #expect(registry.executingTabIds == [tabB])
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
