import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct TaskCancellationShieldTests {
    /// What the shield exists for. A driver reads `Task.isCancelled` or installs a
    /// `withTaskCancellationHandler`, and a COMMIT sent from an already-cancelled task would be
    /// aborted before it reached the socket.
    @Test("Work inside the shield never sees the cancellation of the task awaiting it")
    func shieldedWorkNeverSeesCancellation() async {
        let observed = Observation()
        let started = AsyncGate()
        let cancelIssued = AsyncGate()
        let task = Task {
            try await TaskCancellationShield.run {
                await withTaskCancellationHandler {
                    observed.record(cancelled: Task.isCancelled)
                    await started.open()
                    await cancelIssued.wait()
                    observed.record(cancelledAtEnd: Task.isCancelled)
                } onCancel: {
                    observed.recordHandlerFired()
                }
            }
        }
        await started.wait()
        task.cancel()
        await cancelIssued.open()
        try? await task.value

        #expect(observed.sawCancellationAtStart == false)
        #expect(observed.sawCancellationAtEnd == false)
        #expect(observed.handlerFired == false)
    }

    /// The same work without the shield, so the test proves the shield is what makes the
    /// difference rather than the probe being unable to see a cancellation at all.
    @Test("The same work run structurally does see it")
    func structuredWorkSeesCancellation() async {
        let observed = Observation()
        let started = AsyncGate()
        let task = Task {
            await withTaskCancellationHandler {
                await started.open()
                // Parks until the cancel arrives, which ends the sleep at once.
                try? await Task.sleep(for: .seconds(60))
                observed.record(cancelledAtEnd: Task.isCancelled)
            } onCancel: {
                observed.recordHandlerFired()
            }
        }
        await started.wait()
        task.cancel()
        await task.value

        #expect(observed.sawCancellationAtEnd)
        #expect(observed.handlerFired)
    }

    @Test("A cancelled caller still gets the value the shielded work produced")
    func shieldedWorkStillReturnsItsValue() async throws {
        let cancelIssued = AsyncGate()
        let task = Task { () -> Int in
            try await TaskCancellationShield.run {
                await cancelIssued.wait()
                return 42
            }
        }
        task.cancel()
        await cancelIssued.open()
        #expect(try await task.value == 42)
    }

    @Test("An error the shielded work throws reaches the caller unchanged")
    func shieldedWorkPropagatesItsError() async {
        await #expect(throws: ProbeError.self) {
            try await TaskCancellationShield.run { throw ProbeError.refused }
        }
    }
}

private enum ProbeError: Error {
    case refused
}

/// A cancellation handler runs synchronously inside `cancel()`, so it records under a lock rather
/// than through a task that could land after the assertions.
private final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledAtStart = false
    private var cancelledAtEnd = false
    private var handlerRan = false

    var sawCancellationAtStart: Bool { lock.withLock { cancelledAtStart } }
    var sawCancellationAtEnd: Bool { lock.withLock { cancelledAtEnd } }
    var handlerFired: Bool { lock.withLock { handlerRan } }

    func record(cancelled: Bool) {
        lock.withLock { cancelledAtStart = cancelled }
    }

    func record(cancelledAtEnd: Bool) {
        lock.withLock { self.cancelledAtEnd = cancelledAtEnd }
    }

    func recordHandlerFired() {
        lock.withLock { handlerRan = true }
    }
}
