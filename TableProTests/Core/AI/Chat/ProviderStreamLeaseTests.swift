//
//  ProviderStreamLeaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Provider stream lease")
@MainActor
struct ProviderStreamLeaseTests {
    @Test("The first session takes the lease without waiting")
    func firstSessionTakesLease() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let session = UUID()

        await lease.acquire(configId: config, sessionId: session)

        #expect(lease.holdingSession(configId: config) == session)
        #expect(lease.isWaiting(sessionId: session) == false)
    }

    @Test("A session already holding the lease re-acquires without waiting")
    func reentrantAcquireDoesNotDeadlock() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let session = UUID()

        await lease.acquire(configId: config, sessionId: session)
        await lease.acquire(configId: config, sessionId: session)

        #expect(lease.holdingSession(configId: config) == session)
    }

    @Test("A second session on the same configuration waits, and the wait is reportable")
    func secondSessionQueues() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let first = UUID()
        let second = UUID()

        await lease.acquire(configId: config, sessionId: first)
        let waiter = Task { await lease.acquire(configId: config, sessionId: second) }
        while !lease.isWaiting(sessionId: second) {
            await Task.yield()
        }

        #expect(lease.holdingSession(configId: config) == first)
        #expect(lease.waitReason(sessionId: second) { _ in "Copilot" } == "Waiting for another session on Copilot")

        lease.release(configId: config, sessionId: first)
        await waiter.value

        #expect(lease.holdingSession(configId: config) == second)
        #expect(lease.isWaiting(sessionId: second) == false)
    }

    @Test("A session on a different configuration never waits")
    func differentConfigurationsDoNotQueue() async {
        let lease = ProviderStreamLease()
        let first = UUID()
        let second = UUID()
        let firstConfig = UUID()
        let secondConfig = UUID()

        await lease.acquire(configId: firstConfig, sessionId: first)
        await lease.acquire(configId: secondConfig, sessionId: second)

        #expect(lease.holdingSession(configId: firstConfig) == first)
        #expect(lease.holdingSession(configId: secondConfig) == second)
    }

    @Test("Releasing hands the lease to the waiter that arrived first")
    func queueIsFirstComeFirstServed() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let holder = UUID()
        let second = UUID()
        let third = UUID()

        await lease.acquire(configId: config, sessionId: holder)
        let secondWaiter = Task { await lease.acquire(configId: config, sessionId: second) }
        while !lease.isWaiting(sessionId: second) {
            await Task.yield()
        }
        let thirdWaiter = Task { await lease.acquire(configId: config, sessionId: third) }
        while !lease.isWaiting(sessionId: third) {
            await Task.yield()
        }

        lease.release(configId: config, sessionId: holder)
        await secondWaiter.value
        #expect(lease.holdingSession(configId: config) == second)

        lease.release(configId: config, sessionId: second)
        await thirdWaiter.value
        #expect(lease.holdingSession(configId: config) == third)
    }

    @Test("A session that does not hold the lease cannot release it")
    func releaseByNonHolderIsIgnored() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let holder = UUID()

        await lease.acquire(configId: config, sessionId: holder)
        lease.release(configId: config, sessionId: UUID())

        #expect(lease.holdingSession(configId: config) == holder)
    }

    @Test("releaseAll frees what a session holds and wakes it out of the queue it stands in")
    func releaseAllClearsHeldAndQueued() async {
        let lease = ProviderStreamLease()
        let heldConfig = UUID()
        let busyConfig = UUID()
        let session = UUID()
        let other = UUID()

        await lease.acquire(configId: heldConfig, sessionId: session)
        await lease.acquire(configId: busyConfig, sessionId: other)
        let queued = Task { await lease.acquire(configId: busyConfig, sessionId: session) }
        while !lease.isWaiting(sessionId: session) {
            await Task.yield()
        }

        lease.releaseAll(sessionId: session)
        await queued.value

        #expect(lease.holdingSession(configId: heldConfig) == nil)
        #expect(lease.isWaiting(sessionId: session) == false)
        #expect(lease.holdingSession(configId: busyConfig) == other)
    }

    @Test("withLease waits for the holder, then frees the lease again")
    func withLeaseWaitsAndReleases() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let holder = UUID()
        let session = UUID()
        var ran = false

        await lease.acquire(configId: config, sessionId: holder)
        let work = Task { await lease.withLease(configId: config, sessionId: session) { ran = true } }
        while !lease.isWaiting(sessionId: session) {
            await Task.yield()
        }
        #expect(ran == false)

        lease.release(configId: config, sessionId: holder)
        await work.value

        #expect(ran)
        #expect(lease.holdingSession(configId: config) == nil)
    }

    @Test("withLease keeps the lease when the session already holds it")
    func withLeaseIsReentrantAndDoesNotRelease() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let session = UUID()
        var ran = false

        await lease.acquire(configId: config, sessionId: session)
        await lease.withLease(configId: config, sessionId: session) { ran = true }

        #expect(ran)
        #expect(lease.holdingSession(configId: config) == session)
    }

    @Test("A session that is not waiting has no wait reason")
    func noWaitReasonWhenRunning() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let session = UUID()

        await lease.acquire(configId: config, sessionId: session)

        #expect(lease.waitReason(sessionId: session) { _ in "Copilot" } == nil)
    }

    @Test("An unnamed provider still reports a wait reason")
    func waitReasonWithoutProviderName() async {
        let lease = ProviderStreamLease()
        let config = UUID()
        let first = UUID()
        let second = UUID()

        await lease.acquire(configId: config, sessionId: first)
        let waiter = Task { await lease.acquire(configId: config, sessionId: second) }
        while !lease.isWaiting(sessionId: second) {
            await Task.yield()
        }

        #expect(lease.waitReason(sessionId: second) { _ in nil } == "Waiting for another session on the same provider")

        lease.release(configId: config, sessionId: first)
        await waiter.value
    }
}
