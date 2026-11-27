//
//  SSHSessionRegistryTests.swift
//  TableProTests
//

import Foundation
import os
import TableProTestSupport
import Testing

@testable import TablePro

private final class FakeSession: SSHSharedTransport, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (running: true, closes: 0))

    var isRunning: Bool { state.withLock { $0.running } }
    var closes: Int { state.withLock { $0.closes } }

    func close() {
        state.withLock {
            $0.running = false
            $0.closes += 1
        }
    }

    func die() {
        state.withLock { $0.running = false }
    }
}

// Counts sign-ins and holds each one until the test lets it finish.
private final class SignIns: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (started: 0, cancelled: 0))
    let gate = AsyncGate()
    let failure: (any Error)?

    init(failing failure: (any Error)? = nil) {
        self.failure = failure
    }

    var started: Int { state.withLock { $0.started } }
    var cancelled: Int { state.withLock { $0.cancelled } }

    func make() async throws -> FakeSession {
        state.withLock { $0.started += 1 }
        await gate.wait()
        if Task.isCancelled {
            state.withLock { $0.cancelled += 1 }
            throw CancellationError()
        }
        if let failure { throw failure }
        return FakeSession()
    }
}

private struct SignInRefused: Error, Equatable {}

struct SSHSessionRegistryTests {
    private typealias Registry = SSHSessionRegistry<String, FakeSession>

    @Test("Connections that start together on one route share one sign-in and one session")
    func concurrentAcquiresShareOneSignIn() async throws {
        let registry = Registry()
        let signIns = SignIns()

        async let first = registry.acquire("bastion") { try await signIns.make() }
        async let second = registry.acquire("bastion") { try await signIns.make() }
        try await waitUntil { signIns.started == 1 }
        await signIns.gate.open()

        let leases = try await [first, second]
        #expect(signIns.started == 1)
        #expect(leases[0].session === leases[1].session)
        #expect(leases[0].token != leases[1].token)
    }

    @Test("A connection on a live route takes the session without signing in")
    func liveSessionIsReused() async throws {
        let registry = Registry()
        let signIns = SignIns()
        await signIns.gate.open()

        let first = try await registry.acquire("bastion") { try await signIns.make() }
        let second = try await registry.acquire("bastion") { try await signIns.make() }

        #expect(signIns.started == 1)
        #expect(!first.reused)
        #expect(second.reused)
        #expect(first.session === second.session)
    }

    @Test("Different routes get their own sessions")
    func differentRoutesSignInSeparately() async throws {
        let registry = Registry()
        let signIns = SignIns()
        await signIns.gate.open()

        let first = try await registry.acquire("bastion-a") { try await signIns.make() }
        let second = try await registry.acquire("bastion-b") { try await signIns.make() }

        #expect(signIns.started == 2)
        #expect(first.session !== second.session)
    }

    @Test("The session closes when its last lease goes back, not before")
    func lastReleaseClosesSession() async throws {
        let registry = Registry()
        let signIns = SignIns()
        await signIns.gate.open()
        let first = try await registry.acquire("bastion") { try await signIns.make() }
        let second = try await registry.acquire("bastion") { try await signIns.make() }

        await registry.release("bastion", token: first.token)
        #expect(first.session.closes == 0)

        await registry.release("bastion", token: second.token)
        #expect(first.session.closes == 1)
        #expect(await registry.liveSessionCount == 0)
    }

    @Test("A refused sign-in fails every connection waiting on it, and the next one tries again")
    func failedSignInFailsEveryWaiter() async throws {
        let registry = Registry()
        let signIns = SignIns(failing: SignInRefused())

        let first = Task { try await registry.acquire("bastion") { try await signIns.make() } }
        let second = Task { try await registry.acquire("bastion") { try await signIns.make() } }
        try await waitUntil { await registry.waiterCount("bastion") == 2 }
        await signIns.gate.open()

        await #expect(throws: SignInRefused.self) { try await first.value }
        await #expect(throws: SignInRefused.self) { try await second.value }

        await #expect(throws: SignInRefused.self) {
            try await registry.acquire("bastion") { try await signIns.make() }
        }
        #expect(signIns.started == 2)
    }

    @Test("A cancelled waiter leaves without failing the others, who still get the session")
    func cancelledWaiterLeavesAlone() async throws {
        let registry = Registry()
        let signIns = SignIns()

        let leaving = Task { try await registry.acquire("bastion") { try await signIns.make() } }
        try await waitUntil { signIns.started == 1 }
        async let staying = registry.acquire("bastion") { try await signIns.make() }
        try await waitUntil { await registry.waiterCount("bastion") == 2 }
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        await signIns.gate.open()

        let lease = try await staying
        #expect(lease.session.isRunning)
        #expect(signIns.cancelled == 0)
    }

    @Test("When every waiter leaves, the sign-in is cancelled and a new acquire starts its own")
    func lastWaiterLeavingCancelsSignIn() async throws {
        let registry = Registry()
        let signIns = SignIns()

        let leaving = Task { try await registry.acquire("bastion") { try await signIns.make() } }
        try await waitUntil { signIns.started == 1 }
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }

        async let fresh = registry.acquire("bastion") { try await signIns.make() }
        try await waitUntil { signIns.started == 2 }
        await signIns.gate.open()

        let lease = try await fresh
        #expect(lease.session.isRunning)
        try await waitUntil { signIns.cancelled == 1 }
    }

    @Test("A dead session is replaced by the next acquire, and an old lease never drops a holder of the new one")
    func deadSessionIsReplaced() async throws {
        let registry = Registry()
        let signIns = SignIns()
        await signIns.gate.open()
        let old = try await registry.acquire("bastion") { try await signIns.make() }
        old.session.die()

        let replacement = try await registry.acquire("bastion") { try await signIns.make() }
        await registry.release("bastion", token: old.token)

        #expect(replacement.session !== old.session)
        #expect(!replacement.reused)
        #expect(replacement.session.closes == 0)
        #expect(await registry.liveSessionCount == 1)
    }

    @Test("Forgetting a dead session leaves a newer one in place")
    func forgetOnlyTheSameSession() async throws {
        let registry = Registry()
        let signIns = SignIns()
        await signIns.gate.open()
        let old = try await registry.acquire("bastion") { try await signIns.make() }
        old.session.die()
        let replacement = try await registry.acquire("bastion") { try await signIns.make() }

        await registry.forget("bastion", session: old.session)

        let next = try await registry.acquire("bastion") { try await signIns.make() }
        #expect(next.session === replacement.session)
    }

    @Test("A waiter leaves at its own deadline while the sign-in it joined goes on for the others")
    func waiterLeavesAtItsOwnDeadline() async throws {
        let registry = Registry()
        let signIns = SignIns()

        async let patient = registry.acquire("bastion") { try await signIns.make() }
        try await waitUntil { signIns.started == 1 }
        await #expect(throws: WaiterTimedOut.self) {
            try await registry.acquire(
                "bastion",
                deadline: .now.advanced(by: .milliseconds(50)),
                timedOut: { WaiterTimedOut() }
            ) { try await signIns.make() }
        }
        await signIns.gate.open()

        let lease = try await patient
        #expect(lease.session.isRunning)
        #expect(signIns.started == 1)
        #expect(signIns.cancelled == 0)
    }
}

private struct WaiterTimedOut: Error {}
