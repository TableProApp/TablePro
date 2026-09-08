//
//  TransportRateSampler.swift
//  TablePro
//

import Foundation

struct TransportRate: Equatable, Sendable {
    let receivedPerSecond: Double
    let sentPerSecond: Double

    static let zero = TransportRate(receivedPerSecond: 0, sentPerSecond: 0)

    /// Below a byte a second in both directions there is nothing to report, and a rate that rounds
    /// to "0 B/s" is worse than no rate at all: it reads as a broken connection rather than an idle
    /// one. The readout shows the totals in that case, which stay true whether or not anything is
    /// moving right now.
    var isIdle: Bool {
        receivedPerSecond < 1 && sentPerSecond < 1
    }
}

/// Turns two readings of a `TransportByteCounter` into a rate.
///
/// It divides by the interval it actually measured rather than the one the caller asked for, so a
/// sampler the run loop kept waiting reports the rate over the time that really passed. Holding the
/// baseline here rather than in the view is what lets the arithmetic be tested without a clock.
struct TransportRateSampler {
    private var previousTotals: TransportByteTotals?
    private var previousInstant: ContinuousClock.Instant?

    init() {}

    /// Returns nil for the first reading, which has nothing to be measured against, and for a
    /// counter that went backwards, which means a reconnect installed a fresh transport. Both
    /// re-baseline, so the next reading measures against the new one instead of reporting the whole
    /// of a new tunnel's traffic as one interval's worth.
    mutating func sample(_ totals: TransportByteTotals, at instant: ContinuousClock.Instant) -> TransportRate? {
        defer {
            previousTotals = totals
            previousInstant = instant
        }

        guard let previousTotals, let previousInstant else { return nil }
        guard totals.received >= previousTotals.received, totals.sent >= previousTotals.sent else { return nil }

        let elapsed = Self.seconds(previousInstant.duration(to: instant))
        guard elapsed > 0 else { return nil }

        return TransportRate(
            receivedPerSecond: Double(totals.received - previousTotals.received) / elapsed,
            sentPerSecond: Double(totals.sent - previousTotals.sent) / elapsed
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
