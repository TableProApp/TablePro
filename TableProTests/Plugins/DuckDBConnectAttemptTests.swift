//
//  DuckDBConnectAttemptTests.swift
//  TableProTests
//

import Foundation
import Testing

struct DuckDBConnectAttemptTests {
    @Test("Every bootstrap phase consumes the same injected deadline")
    func phasesShareDeadline() throws {
        let start = ContinuousClock.now
        let attempt = DuckDBConnectAttempt(
            additionalFields: ["connectTimeoutMilliseconds": "2500"],
            now: start,
            interrupt: {}
        )

        #expect(attempt.remainingMilliseconds(at: start) == 2_500)
        #expect(attempt.remainingMilliseconds(at: start.advanced(by: .milliseconds(1_200))) == 1_300)
        #expect(attempt.remainingMilliseconds(at: start.advanced(by: .milliseconds(2_499))) == 1)
        #expect(attempt.remainingMilliseconds(at: start.advanced(by: .milliseconds(2_500))) == nil)
        try attempt.check(at: start.advanced(by: .milliseconds(2_499)))
    }

    @Test("Expiry interrupts once and makes later phase checks fail")
    func expiryInterruptsOnce() {
        let start = ContinuousClock.now
        let recorder = DuckDBConnectInterruptRecorder()
        let attempt = DuckDBConnectAttempt(
            additionalFields: ["connectTimeoutMilliseconds": "1000"],
            now: start,
            interrupt: { recorder.record() }
        )

        attempt.expire(at: start.advanced(by: .milliseconds(999)))
        #expect(!recorder.didInterrupt)

        attempt.expire(at: start.advanced(by: .milliseconds(1_000)))
        attempt.expire(at: start.advanced(by: .milliseconds(2_000)))
        #expect(recorder.count == 1)
        #expect(throws: DuckDBConnectAttemptError.timedOut) {
            try attempt.check(at: start.advanced(by: .milliseconds(2_000)))
        }
    }

    @Test("Cancellation interrupts synchronously and remains cancellation")
    func cancellationInterrupts() {
        let recorder = DuckDBConnectInterruptRecorder()
        let attempt = DuckDBConnectAttempt(
            additionalFields: ["connectTimeoutMilliseconds": "1000"],
            interrupt: { recorder.record() }
        )

        attempt.cancel()
        #expect(recorder.count == 1)
        #expect(throws: CancellationError.self) {
            try attempt.check()
        }
        #expect(attempt.stop() is CancellationError)
    }

    @Test("A late result cannot be adopted after the deadline")
    func deadlineFencesLateAdoption() {
        let start = ContinuousClock.now
        let recorder = DuckDBConnectInterruptRecorder()
        let attempt = DuckDBConnectAttempt(
            additionalFields: ["connectTimeoutMilliseconds": "1000"],
            now: start,
            interrupt: { recorder.record() }
        )
        var adopted = false

        #expect(throws: DuckDBConnectAttemptError.timedOut) {
            try attempt.finish(at: start.advanced(by: .milliseconds(1_000))) {
                adopted = true
            }
        }

        #expect(!adopted)
        #expect(recorder.count == 1)
    }

    @Test("A result adopted before the deadline ignores a stale timer")
    func adoptionFencesStaleTimer() throws {
        let start = ContinuousClock.now
        let recorder = DuckDBConnectInterruptRecorder()
        let attempt = DuckDBConnectAttempt(
            additionalFields: ["connectTimeoutMilliseconds": "1000"],
            now: start,
            interrupt: { recorder.record() }
        )
        var adopted = false

        try attempt.finish(at: start.advanced(by: .milliseconds(999))) {
            adopted = true
        }
        attempt.expire(at: start.advanced(by: .milliseconds(1_000)))

        #expect(adopted)
        #expect(!recorder.didInterrupt)
    }
}

private final class DuckDBConnectInterruptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    var didInterrupt: Bool {
        lock.withLock { value > 0 }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}
