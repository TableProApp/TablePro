//
//  TabExecutionEndReasonTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The reason is a required parameter rather than a defaulted one on purpose: a new way to end an
/// execution is then a compile error at the new call site instead of a silent gap. The list of
/// cancel sites this replaced was already incomplete when it was written.
@Suite("Execution end reasons")
struct TabExecutionEndReasonTests {
    @Test("Invalidating a claimed tab reports what was ended and why")
    func invalidateReportsTheEndedExecution() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)

        let ended = registry.invalidate(tabId, reason: .cancelledByUser)

        #expect(ended?.tabId == tabId)
        #expect(ended?.reason == .cancelledByUser)
        #expect(ended?.startedAt == claim.startedAt)
        #expect(!registry.isExecuting(tabId))
    }

    @Test("Invalidating a tab that was not running reports nothing")
    func invalidateWithoutAClaimReportsNothing() {
        var registry = TabExecutionRegistry()
        #expect(registry.invalidate(UUID(), reason: .sessionEnded) == nil)
    }

    @Test("Invalidating everything reports every running tab once")
    func invalidateAllReportsEveryRunningTab() {
        var registry = TabExecutionRegistry()
        let running = [UUID(), UUID()]
        for tabId in running { _ = registry.claim(tabId) }
        let idle = UUID()
        _ = registry.claim(idle)
        _ = registry.settle(registry.claim(idle))

        let ended = registry.invalidateAll(reason: .sessionEnded)

        #expect(Set(ended.map(\.tabId)) == Set(running))
        #expect(ended.allSatisfy { $0.reason == .sessionEnded })
    }

    /// The claim carries the start instant because no terminal point can recover it afterwards:
    /// the driver-reported execution time excludes queueing and tunnel setup, and the failure path
    /// records zero.
    @Test("A claim carries when its work started")
    func claimCarriesItsStart() {
        var registry = TabExecutionRegistry()
        let started = ContinuousClock.Instant.now
        let claim = registry.claim(UUID(), startedAt: started)
        #expect(claim.startedAt == started)
    }
}
