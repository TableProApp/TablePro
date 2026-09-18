//
//  TeardownLatchTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// The latch exists because two paths can decide a tunnel is over at the same moment, and exactly
/// one of them has to release its listening socket, session and jump hops.
@Suite("Teardown latch")
struct TeardownLatchTests {
    @Test("The first claim wins and every later one loses")
    func onlyTheFirstClaimWins() {
        let latch = TeardownLatch()
        #expect(latch.claim())
        #expect(!latch.claim())
        #expect(!latch.claim())
    }

    @Test("A latch starts live and stops being live once claimed")
    func claimingEndsTheLifetime() {
        let latch = TeardownLatch()
        #expect(latch.isLive)
        _ = latch.claim()
        #expect(!latch.isLive)
    }

    @Test("Observing does not claim")
    func observingIsNotClaiming() {
        let latch = TeardownLatch()
        #expect(latch.isLive)
        #expect(latch.isLive)
        #expect(latch.claim(), "reading isLive must leave the claim available")
    }

    /// The case the tunnel actually hits: the app closes it in the same instant its keep-alive
    /// notices the server has gone. Exactly one of them owes the teardown, whichever arrives first.
    @Test("Exactly one of many concurrent claimants wins")
    func concurrentClaimantsProduceOneWinner() async {
        for _ in 0..<200 {
            let latch = TeardownLatch()
            let winners = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask { latch.claim() }
                }
                var count = 0
                for await didWin in group where didWin { count += 1 }
                return count
            }
            #expect(winners == 1)
        }
    }
}
