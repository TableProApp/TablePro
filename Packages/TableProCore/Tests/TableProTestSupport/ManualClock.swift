import Foundation

/// Time moves only when a case advances it, so no case races the wall clock or a busy main actor.
public final class ManualClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol {
        public let offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
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

    public init() {}

    public var now: Instant {
        lock.withLock { current }
    }

    public var minimumResolution: Duration {
        .zero
    }

    public var pendingSleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            removeSleeper(id: id)?.continuation.resume(throwing: CancellationError())
        }
    }

    public func waitUntilSleeping() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSleeping = lock.withLock {
                guard sleepers.isEmpty else { return true }
                sleeperWaiters.append(continuation)
                return false
            }
            if isSleeping { continuation.resume() }
        }
    }

    public func advance(by duration: Duration) {
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
