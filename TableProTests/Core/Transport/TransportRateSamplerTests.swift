//
//  TransportRateSamplerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TransportRateSampler")
struct TransportRateSamplerTests {
    private let start = ContinuousClock.now

    @Test("The first reading has nothing to measure against")
    func firstReadingHasNoRate() {
        var sampler = TransportRateSampler()

        #expect(sampler.sample(TransportByteTotals(received: 1_000, sent: 500), at: start) == nil)
    }

    @Test("A rate is the delta over the interval that actually elapsed")
    func measuresOverTheElapsedInterval() {
        var sampler = TransportRateSampler()
        _ = sampler.sample(TransportByteTotals(received: 1_000, sent: 500), at: start)

        let rate = sampler.sample(
            TransportByteTotals(received: 5_000, sent: 700),
            at: start.advanced(by: .seconds(2))
        )

        #expect(rate?.receivedPerSecond == 2_000)
        #expect(rate?.sentPerSecond == 100)
    }

    /// A sampler the run loop kept waiting must divide by the time that passed, not by the one it
    /// asked for, or a late sample overstates the rate by exactly how late it was.
    @Test("A late sample reports the rate over its own longer interval")
    func lateSampleDividesByItsOwnInterval() {
        var sampler = TransportRateSampler()
        _ = sampler.sample(.zero, at: start)

        let rate = sampler.sample(
            TransportByteTotals(received: 8_000, sent: 0),
            at: start.advanced(by: .seconds(4))
        )

        #expect(rate?.receivedPerSecond == 2_000)
    }

    @Test("Sub-second intervals scale up")
    func subSecondInterval() {
        var sampler = TransportRateSampler()
        _ = sampler.sample(.zero, at: start)

        let rate = sampler.sample(
            TransportByteTotals(received: 250, sent: 0),
            at: start.advanced(by: .milliseconds(500))
        )

        #expect(rate?.receivedPerSecond == 500)
    }

    /// A reconnect installs a fresh transport with a counter at zero. Measuring against the dead
    /// one's totals would make the next reading negative, and the one after it report a whole new
    /// tunnel's traffic as a single interval's worth.
    @Test("A counter that went backwards re-baselines instead of reporting a rate")
    func rebaselinesAfterAReset() {
        var sampler = TransportRateSampler()
        _ = sampler.sample(TransportByteTotals(received: 10_000, sent: 4_000), at: start)

        let afterReset = sampler.sample(.zero, at: start.advanced(by: .seconds(1)))
        #expect(afterReset == nil)

        let next = sampler.sample(
            TransportByteTotals(received: 300, sent: 0),
            at: start.advanced(by: .seconds(2))
        )
        #expect(next?.receivedPerSecond == 300)
    }

    @Test("Two readings at the same instant report no rate")
    func zeroElapsedReportsNothing() {
        var sampler = TransportRateSampler()
        _ = sampler.sample(.zero, at: start)

        #expect(sampler.sample(TransportByteTotals(received: 100, sent: 0), at: start) == nil)
    }

    @Test("An unchanged counter reports an idle rate")
    func unchangedCounterIsIdle() {
        var sampler = TransportRateSampler()
        let totals = TransportByteTotals(received: 9_000, sent: 3_000)
        _ = sampler.sample(totals, at: start)

        let rate = sampler.sample(totals, at: start.advanced(by: .seconds(1)))

        #expect(rate == .zero)
        #expect(rate?.isIdle == true)
    }

    @Test("A rate under a byte a second counts as idle")
    func slowTrickleIsIdle() {
        #expect(TransportRate(receivedPerSecond: 0.4, sentPerSecond: 0.9).isIdle)
        #expect(!TransportRate(receivedPerSecond: 1, sentPerSecond: 0).isIdle)
        #expect(!TransportRate(receivedPerSecond: 0, sentPerSecond: 42).isIdle)
    }
}
