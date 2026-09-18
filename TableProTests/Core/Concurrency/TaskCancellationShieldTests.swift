//
//  TaskCancellationShieldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Task cancellation shield")
struct TaskCancellationShieldTests {
    /// What the shield exists for. A driver reads `Task.isCancelled` or installs a
    /// `withTaskCancellationHandler`, and a COMMIT sent from an already-cancelled task would be
    /// aborted before it reached the socket.
    @Test("Work inside the shield never sees the cancellation of the task awaiting it")
    func shieldedWorkNeverSeesCancellation() async {
        let observed = Observation()
        let task = Task {
            try await TaskCancellationShield.run {
                await withTaskCancellationHandler {
                    await observed.record(cancelled: Task.isCancelled)
                    try? await Task.sleep(for: .milliseconds(30))
                    await observed.record(cancelledAtEnd: Task.isCancelled)
                } onCancel: {
                    Task { await observed.recordHandlerFired() }
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        task.cancel()
        try? await task.value

        #expect(await observed.sawCancellationAtStart == false)
        #expect(await observed.sawCancellationAtEnd == false)
        #expect(await observed.handlerFired == false)
    }

    /// The same work without the shield, so the test proves the shield is what makes the
    /// difference rather than the probe being unable to see a cancellation at all.
    @Test("The same work run structurally does see it")
    func structuredWorkSeesCancellation() async {
        let observed = Observation()
        let task = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .milliseconds(30))
                await observed.record(cancelledAtEnd: Task.isCancelled)
            } onCancel: {
                Task { await observed.recordHandlerFired() }
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        task.cancel()
        await task.value
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await observed.sawCancellationAtEnd)
        #expect(await observed.handlerFired)
    }

    @Test("A cancelled caller still gets the value the shielded work produced")
    func shieldedWorkStillReturnsItsValue() async throws {
        let task = Task { () -> Int in
            try await TaskCancellationShield.run {
                try? await Task.sleep(for: .milliseconds(20))
                return 42
            }
        }
        task.cancel()
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

private actor Observation {
    private(set) var sawCancellationAtStart = false
    private(set) var sawCancellationAtEnd = false
    private(set) var handlerFired = false

    func record(cancelled: Bool) {
        sawCancellationAtStart = cancelled
    }

    func record(cancelledAtEnd: Bool) {
        sawCancellationAtEnd = cancelledAtEnd
    }

    func recordHandlerFired() {
        handlerFired = true
    }
}
