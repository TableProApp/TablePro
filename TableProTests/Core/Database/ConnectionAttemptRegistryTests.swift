//
//  ConnectionAttemptRegistryTests.swift
//  TableProTests
//
//  Pins #1358: a cancelled or superseded connection attempt keeps running when its
//  driver blocks in a C call, so it must never adopt into or tear down the session
//  that a newer attempt owns.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection attempt registry")
struct ConnectionAttemptRegistryTests {
    @Test("The only attempt for a connection is current")
    func singleAttemptIsCurrent() {
        var registry = ConnectionAttemptRegistry()
        let id = UUID()

        let attempt = registry.begin(for: id)

        #expect(registry.isCurrent(attempt, for: id))
    }

    @Test("A newer attempt supersedes the one in flight")
    func newerAttemptSupersedesOlder() {
        var registry = ConnectionAttemptRegistry()
        let id = UUID()

        let first = registry.begin(for: id)
        let second = registry.begin(for: id)

        #expect(!registry.isCurrent(first, for: id))
        #expect(registry.isCurrent(second, for: id))
    }

    @Test("Cancelling invalidates the attempt in flight")
    func cancelInvalidatesInFlightAttempt() {
        var registry = ConnectionAttemptRegistry()
        let id = UUID()
        let attempt = registry.begin(for: id)

        registry.invalidate(for: id)

        #expect(!registry.isCurrent(attempt, for: id))
    }

    @Test("A cancelled attempt completing late cannot claim the retry that replaced it")
    func lateCancelledAttemptCannotClaimRetry() {
        var registry = ConnectionAttemptRegistry()
        let id = UUID()

        let cancelled = registry.begin(for: id)
        registry.invalidate(for: id)
        let retry = registry.begin(for: id)

        #expect(!registry.isCurrent(cancelled, for: id))
        #expect(registry.isCurrent(retry, for: id))
    }

    @Test("Finishing an attempt does not invalidate the attempt that superseded it")
    func finishingStaleAttemptLeavesCurrentIntact() {
        var registry = ConnectionAttemptRegistry()
        let id = UUID()

        let stale = registry.begin(for: id)
        let current = registry.begin(for: id)
        registry.finish(stale, for: id)

        #expect(registry.isCurrent(current, for: id))
    }

    @Test("Attempts are tracked per connection")
    func attemptsAreScopedPerConnection() {
        var registry = ConnectionAttemptRegistry()
        let first = UUID()
        let second = UUID()

        let firstAttempt = registry.begin(for: first)
        let secondAttempt = registry.begin(for: second)
        registry.invalidate(for: second)

        #expect(registry.isCurrent(firstAttempt, for: first))
        #expect(!registry.isCurrent(secondAttempt, for: second))
    }

    @Test("A finished attempt is no longer current")
    func finishedAttemptIsNotCurrent() {
        var registry = ConnectionAttemptRegistry()
        let id = UUID()
        let attempt = registry.begin(for: id)

        registry.finish(attempt, for: id)

        #expect(!registry.isCurrent(attempt, for: id))
    }
}
