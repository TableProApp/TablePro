//
//  CopilotIdleStopControllerTests.swift
//  TableProTests
//
//  Verifies the deferred-stop state machine extracted from CopilotService.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class TestState {
    var authenticated: Bool
    var running: Bool
    var stopCount: Int = 0

    init(authenticated: Bool = false, running: Bool = true) {
        self.authenticated = authenticated
        self.running = running
    }
}

/// Time moves only when a case advances it, so no case races the wall clock or a busy main actor.
private final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    var now: Instant {
        lock.withLock { current }
    }

    var minimumResolution: Swift.Duration {
        .zero
    }

    var pendingSleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            removeSleeper(id: id)?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleeping() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSleeping = lock.withLock {
                guard sleepers.isEmpty else { return true }
                sleeperWaiters.append(continuation)
                return false
            }
            if isSleeping { continuation.resume() }
        }
    }

    func advance(by duration: Swift.Duration) {
        let due = lock.withLock {
            current = current.advanced(by: duration)
            let reached = current
            let woken = sleepers.filter { $0.deadline <= reached }
            sleepers.removeAll { $0.deadline <= reached }
            return woken
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func enqueue(_ sleeper: Sleeper) {
        enum Admission {
            case wake
            case cancel
            case wait([CheckedContinuation<Void, Never>])
        }
        let admission: Admission = lock.withLock {
            if Task.isCancelled { return .cancel }
            if sleeper.deadline <= current { return .wake }
            sleepers.append(sleeper)
            let waiters = sleeperWaiters
            sleeperWaiters.removeAll()
            return .wait(waiters)
        }
        switch admission {
        case .wake:
            sleeper.continuation.resume()
        case .cancel:
            sleeper.continuation.resume(throwing: CancellationError())
        case .wait(let waiters):
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func removeSleeper(id: UUID) -> Sleeper? {
        lock.withLock {
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return sleepers.remove(at: index)
        }
    }
}

@MainActor
struct CopilotIdleStopControllerTests {
    private static let timeout: Duration = .seconds(300)

    private let clock = ManualClock()

    private func makeController(state: TestState) -> CopilotIdleStopController {
        CopilotIdleStopController(
            timeout: Self.timeout,
            clock: clock,
            isAuthenticated: { state.authenticated },
            isRunning: { state.running },
            onStopRequest: { state.stopCount += 1 }
        )
    }

    @Test("Stops when timer fires while unauthenticated and running")
    func stopsAfterTimeout() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        clock.advance(by: Self.timeout - .milliseconds(1))

        #expect(clock.pendingSleeperCount == 1)
        #expect(state.stopCount == 0)

        clock.advance(by: .milliseconds(1))
        await timer.value

        #expect(state.stopCount == 1)
    }

    @Test("Skips when already authenticated at schedule time")
    func skipsWhenAuthenticated() {
        let state = TestState(authenticated: true)
        let controller = makeController(state: state)

        #expect(controller.schedule() == nil)
        #expect(clock.pendingSleeperCount == 0)
        #expect(state.stopCount == 0)
    }

    @Test("Skips when authenticated by fire time")
    func skipsWhenAuthenticatedByFireTime() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        state.authenticated = true
        clock.advance(by: Self.timeout)
        await timer.value

        #expect(state.stopCount == 0)
    }

    @Test("Skips when not running by fire time")
    func skipsWhenNotRunningByFireTime() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        state.running = false
        await clock.waitUntilSleeping()
        clock.advance(by: Self.timeout)
        await timer.value

        #expect(state.stopCount == 0)
    }

    @Test("Cancel before fire prevents stop")
    func cancelPreventsStop() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        controller.cancel()
        clock.advance(by: Self.timeout)
        await timer.value

        #expect(clock.pendingSleeperCount == 0)
        #expect(state.stopCount == 0)
    }

    @Test("Reschedule cancels prior timer; only fires once")
    func rescheduleFiresOnce() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let first = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        let second = try #require(controller.schedule())
        await first.value
        await clock.waitUntilSleeping()
        clock.advance(by: Self.timeout)
        await second.value

        #expect(state.stopCount == 1)
    }
}
