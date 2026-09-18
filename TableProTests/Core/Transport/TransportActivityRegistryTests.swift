//
//  TransportActivityRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TransportActivityRegistry")
struct TransportActivityRegistryTests {
    @Test("A counter reports its totals through the registry")
    func readsBackTheTotals() {
        let registry = TransportActivityRegistry()
        let connectionId = UUID()
        let counter = TransportByteCounter()
        registry.register(counter, for: connectionId)

        counter.recordReceived(4_096)
        counter.recordSent(1_024)

        #expect(registry.totals(for: connectionId) == TransportByteTotals(received: 4_096, sent: 1_024))
    }

    @Test("A connection with no transport has no totals")
    func unknownConnectionHasNothing() {
        #expect(TransportActivityRegistry().totals(for: UUID()) == nil)
    }

    /// The transport owns its counter and the registry only points at it, so teardown needs no call
    /// of its own. An explicit unregister would have to be made from tunnel close, tunnel death and
    /// reconnect alike, and the one that was missed would report a dead tunnel's totals as the live
    /// connection's.
    @Test("Totals disappear when the transport that owned the counter goes")
    func releasingTheCounterClearsTheEntry() {
        let registry = TransportActivityRegistry()
        let connectionId = UUID()

        do {
            let counter = TransportByteCounter()
            registry.register(counter, for: connectionId)
            counter.recordReceived(512)
            #expect(registry.totals(for: connectionId) != nil)
        }

        #expect(registry.totals(for: connectionId) == nil)
        #expect(!registry.measuredConnectionIds.contains(connectionId))
    }

    @Test("Registering again replaces the previous transport's counter")
    func reconnectReplacesTheCounter() {
        let registry = TransportActivityRegistry()
        let connectionId = UUID()

        let first = TransportByteCounter()
        registry.register(first, for: connectionId)
        first.recordReceived(9_000)

        let second = TransportByteCounter()
        registry.register(second, for: connectionId)
        second.recordReceived(10)

        #expect(registry.totals(for: connectionId) == TransportByteTotals(received: 10, sent: 0))
    }

    @Test("Two connections keep separate totals")
    func connectionsAreIndependent() {
        let registry = TransportActivityRegistry()
        let first = UUID()
        let second = UUID()
        let firstCounter = TransportByteCounter()
        let secondCounter = TransportByteCounter()
        registry.register(firstCounter, for: first)
        registry.register(secondCounter, for: second)

        firstCounter.recordReceived(100)
        secondCounter.recordSent(200)

        #expect(registry.totals(for: first) == TransportByteTotals(received: 100, sent: 0))
        #expect(registry.totals(for: second) == TransportByteTotals(received: 0, sent: 200))
    }

    @Test("A non-positive count is not recorded")
    func ignoresEmptyReads() {
        let counter = TransportByteCounter()
        counter.recordReceived(0)
        counter.recordSent(-1)

        #expect(counter.totals == .zero)
    }

    /// One tunnel serves every client socket the driver opens, each relayed on its own task of a
    /// concurrent queue, so the increments genuinely race.
    @Test("Concurrent increments from many relays all land")
    func concurrentIncrementsAllLand() {
        let counter = TransportByteCounter()
        let relays = 8
        let perRelay = 1_000

        DispatchQueue.concurrentPerform(iterations: relays) { _ in
            for _ in 0..<perRelay {
                counter.recordReceived(4)
                counter.recordSent(1)
            }
        }

        #expect(counter.totals.received == UInt64(relays * perRelay * 4))
        #expect(counter.totals.sent == UInt64(relays * perRelay))
    }
}
