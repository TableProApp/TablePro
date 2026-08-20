//
//  SessionDriverGateTests.swift
//  TableProTests
//
//  The gate orders every operation that moves a connection's single shared driver.
//  Without it two windows interleave their pins and each runs against the other's
//  database (#2026). The cancellation tests are the regression guard for #2021: the
//  body must run inline in the caller's task, never in a detached `Task { await
//  previous.value }`, which severs cancellation from the work.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// One-shot rendezvous so a test can wait for work to reach a known point instead
/// of sleeping. Main-actor isolated because the gate is.
@MainActor
private final class TestSignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isSignalled = false

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private final class EventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
private final class BoolBox {
    var value = false
}

private struct GateBodyError: Error, Equatable {}

/// Lets queued work reach its next suspension point without sleeping.
@MainActor
private func drainMainActor(_ times: Int = 8) async {
    for _ in 0..<times {
        await Task.yield()
    }
}

@Suite("SessionDriverGate")
@MainActor
struct SessionDriverGateTests {
    @Test("A second caller for the same connection runs only after the first completes")
    func secondCallerWaitsForTheFirst() async throws {
        let gate = SessionDriverGate()
        let connectionId = UUID()
        let log = EventLog()
        let firstEntered = TestSignal()
        let releaseFirst = TestSignal()

        let first = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                log.record("first-start")
                firstEntered.signal()
                await releaseFirst.wait()
                log.record("first-end")
            }
        }
        await firstEntered.wait()

        let second = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                log.record("second-start")
            }
        }
        await drainMainActor()

        #expect(log.events == ["first-start"])

        releaseFirst.signal()
        try await first.value
        try await second.value

        #expect(log.events == ["first-start", "first-end", "second-start"])
    }

    @Test("A held connection does not block a different connection")
    func differentConnectionsDoNotBlockEachOther() async throws {
        let gate = SessionDriverGate()
        let held = UUID()
        let other = UUID()
        let heldEntered = TestSignal()
        let releaseHeld = TestSignal()

        let holder = Task { @MainActor in
            try await gate.withExclusiveAccess(held) {
                heldEntered.signal()
                await releaseHeld.wait()
            }
        }
        await heldEntered.wait()

        let ran = BoolBox()
        try await gate.withExclusiveAccess(other) {
            ran.value = true
        }

        #expect(ran.value)

        releaseHeld.signal()
        try await holder.value
    }

    @Test("A throwing body still releases the gate")
    func throwingBodyReleasesTheGate() async throws {
        let gate = SessionDriverGate()
        let connectionId = UUID()

        await #expect(throws: GateBodyError.self) {
            try await gate.withExclusiveAccess(connectionId) {
                throw GateBodyError()
            }
        }

        let ran = BoolBox()
        try await gate.withExclusiveAccess(connectionId) {
            ran.value = true
        }

        #expect(ran.value)
    }

    @Test("A cancelled waiter throws and gives up its place in the queue")
    func cancelledWaiterLeavesTheQueue() async throws {
        let gate = SessionDriverGate()
        let connectionId = UUID()
        let log = EventLog()
        let holderEntered = TestSignal()
        let releaseHolder = TestSignal()

        let holder = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()

        let waiter = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                log.record("cancelled-waiter-ran")
            }
        }
        await drainMainActor()

        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(log.events.isEmpty)

        releaseHolder.signal()
        try await holder.value

        let ran = BoolBox()
        try await gate.withExclusiveAccess(connectionId) {
            ran.value = true
        }
        #expect(ran.value)
    }

    @Test("draining a connection fails everyone still queued for it")
    func drainFailsQueuedWaiters() async throws {
        let gate = SessionDriverGate()
        let connectionId = UUID()
        let holderEntered = TestSignal()
        let releaseHolder = TestSignal()

        let holder = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()

        let log = EventLog()
        let waiter = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                log.record("drained-waiter-ran")
            }
        }
        await drainMainActor()

        gate.drain(connectionId: connectionId)

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(log.events.isEmpty)

        releaseHolder.signal()
        try await holder.value
    }

    @Test("The body observes its own task's cancellation")
    func bodyObservesCallerCancellation() async throws {
        let gate = SessionDriverGate()
        let connectionId = UUID()
        let bodyEntered = TestSignal()
        let observedCancellation = BoolBox()

        let work = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                bodyEntered.signal()
                var spins = 0
                while !Task.isCancelled, spins < 10_000 {
                    spins += 1
                    await Task.yield()
                }
                observedCancellation.value = Task.isCancelled
                try Task.checkCancellation()
            }
        }
        await bodyEntered.wait()

        work.cancel()
        await #expect(throws: CancellationError.self) {
            try await work.value
        }

        #expect(
            observedCancellation.value,
            "The body must run inline in the caller's task; a detached body never sees the cancel"
        )
    }

    @Test("Cancelling the holder still releases the gate for the next caller")
    func cancelledHolderReleasesTheGate() async throws {
        let gate = SessionDriverGate()
        let connectionId = UUID()
        let bodyEntered = TestSignal()

        let holder = Task { @MainActor in
            try await gate.withExclusiveAccess(connectionId) {
                bodyEntered.signal()
                var spins = 0
                while !Task.isCancelled, spins < 10_000 {
                    spins += 1
                    await Task.yield()
                }
                try Task.checkCancellation()
            }
        }
        await bodyEntered.wait()

        holder.cancel()
        await #expect(throws: CancellationError.self) {
            try await holder.value
        }

        let ran = BoolBox()
        try await gate.withExclusiveAccess(connectionId) {
            ran.value = true
        }
        #expect(ran.value)
    }
}
