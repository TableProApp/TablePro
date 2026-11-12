//
//  ProtectedWriteDeadlineTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

struct ProtectedWriteDeadlineTests {
    private struct WriteFailed: Error {}

    @Test("A write that finishes in time returns its result")
    func finishesInTime() async throws {
        let lateCompletion = Flag()
        let value = try await DatabaseAccessBridge.awaitProtectedWrite(
            timeout: .seconds(60),
            timeoutSeconds: 60,
            onLateCompletion: { Task { await lateCompletion.set() } },
            { enterDriver in
                try enterDriver()
                return 7
            }
        )

        #expect(value == 7)
        #expect(await !lateCompletion.isSet)
    }

    @Test("A write that fails in time throws its own error")
    func failsInTime() async {
        await #expect(throws: WriteFailed.self) {
            _ = try await DatabaseAccessBridge.awaitProtectedWrite(
                timeout: .seconds(60),
                timeoutSeconds: 60,
                { _ -> Int in throw WriteFailed() }
            )
        }
    }

    @Test("A write that outlives the deadline is reported as outcome unknown, not as a plain timeout")
    func outlivesTheDeadline() async throws {
        let gate = AsyncGate()
        let finished = Flag()
        let lateCompletion = Flag()

        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await DatabaseAccessBridge.awaitProtectedWrite(
                timeout: .milliseconds(20),
                timeoutSeconds: 30,
                onLateCompletion: { Task { await lateCompletion.set() } },
                { enterDriver -> Int in
                    try enterDriver()
                    await gate.wait()
                    await finished.set()
                    return 1
                }
            )
        }

        guard case .timeout(let detail, let context) = error else {
            Issue.record("expected a timeout, got \(String(describing: error))")
            return
        }
        #expect(context?["outcome"] == "unknown")
        #expect(detail.contains("30"))
        #expect(!detail.contains("timed out"))
        #expect(await !finished.isSet)

        await gate.open()
        try await waitUntil { await finished.isSet }
        try await waitUntil { await lateCompletion.isSet }
    }

    @Test("A write still queued at the deadline gets a plain timeout and never runs")
    func queuedAtTheDeadlineIsRefused() async throws {
        let queue = AsyncGate()
        let ran = Flag()
        let refused = Flag()
        let lateCompletion = Flag()

        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await DatabaseAccessBridge.awaitProtectedWrite(
                timeout: .milliseconds(20),
                timeoutSeconds: 30,
                onLateCompletion: { Task { await lateCompletion.set() } },
                { enterDriver -> Int in
                    await queue.wait()
                    do {
                        try enterDriver()
                    } catch {
                        await refused.set()
                        throw error
                    }
                    await ran.set()
                    return 1
                }
            )
        }

        guard case .timeout(let detail, let context) = error else {
            Issue.record("expected a timeout, got \(String(describing: error))")
            return
        }
        #expect(context == nil)
        #expect(detail.contains("timed out"))

        await queue.open()
        try await waitUntil { await refused.isSet }
        #expect(await !ran.isSet)
        #expect(await !lateCompletion.isSet)
    }

    @Test("A write still queued when the caller cancels is refused and never runs")
    func queuedAtCancelIsRefused() async throws {
        let queue = AsyncGate()
        let ran = Flag()
        let refused = Flag()

        let caller = Task {
            try await DatabaseAccessBridge.awaitProtectedWrite(
                timeout: .seconds(60),
                timeoutSeconds: 60,
                { enterDriver -> Int in
                    await queue.wait()
                    do {
                        try enterDriver()
                    } catch {
                        await refused.set()
                        throw error
                    }
                    await ran.set()
                    return 1
                }
            )
        }
        await queue.arrived(1)
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }

        await queue.open()
        try await waitUntil { await refused.isSet }
        #expect(await !ran.isSet)
    }

    @Test("A write already in the driver when the caller cancels runs to the end, and the caller hears it may have been applied")
    func inDriverAtCancelFinishes() async throws {
        let gate = AsyncGate()
        let finished = Flag()
        let lateCompletion = Flag()

        let caller = Task {
            try await DatabaseAccessBridge.awaitProtectedWrite(
                timeout: .seconds(60),
                timeoutSeconds: 60,
                onLateCompletion: { Task { await lateCompletion.set() } },
                { enterDriver -> Int in
                    try enterDriver()
                    await gate.wait()
                    await finished.set()
                    return 1
                }
            )
        }
        await gate.arrived(1)
        caller.cancel()
        let error = await #expect(throws: DatabaseAccessError.self) { _ = try await caller.value }

        guard case .stoppedWhileRunning(let detail) = error else {
            Issue.record("expected the outcome to be unknown, got \(String(describing: error))")
            return
        }
        #expect(detail == DatabaseAccessBridge.stoppedWhileRunning.message)
        #expect(!detail.contains("timed out"))
        #expect(await !finished.isSet)
        #expect(await !lateCompletion.isSet)

        await gate.open()
        try await waitUntil { await finished.isSet }
        try await waitUntil { await lateCompletion.isSet }
    }
}
