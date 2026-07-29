import Foundation
import Testing
@testable import TableProMSSQLCore

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flagged
    }
    func mark() {
        lock.lock(); flagged = true; lock.unlock()
    }
}

private func pollUntil(_ condition: @Sendable () -> Bool, timeout: TimeInterval = 2) async {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > timeout { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private struct TimeoutError: Error {}

@Suite("Connect cancellation")
struct MSSQLConnectCancellationTests {
    @Test("Work that completes normally returns its value")
    func normalCompletion() async throws {
        let queue = DispatchQueue(label: "test.normal")
        let value = try await runCancellableBlocking(on: queue, work: { 42 })
        #expect(value == 42)
    }

    @Test("Cancel returns promptly and the late result is discarded, not adopted")
    func cancelDiscardsLateResult() async {
        let queue = DispatchQueue(label: "test.cancel")
        let workStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let discarded = FlagBox()

        let task = Task {
            try await runCancellableBlocking(
                on: queue,
                work: { () -> Int in
                    workStarted.signal()
                    release.wait()
                    return 7
                },
                discardLateResult: { _ in discarded.mark() }
            )
        }

        workStarted.wait()
        task.cancel()

        let result = await task.result
        if case .success = result {
            Issue.record("expected the cancelled caller to throw")
        }
        #expect(!discarded.value)

        release.signal()
        await pollUntil { discarded.value }
        #expect(discarded.value)
    }

    @Test("A deadline fails the caller and discards the late result")
    func deadlineFires() async {
        let queue = DispatchQueue(label: "test.deadline")
        let release = DispatchSemaphore(value: 0)
        let discarded = FlagBox()

        let result = await Task {
            try await runCancellableBlocking(
                on: queue,
                deadline: .milliseconds(40),
                timeoutError: { TimeoutError() },
                work: { () -> Int in
                    release.wait()
                    return 1
                },
                discardLateResult: { _ in discarded.mark() }
            )
        }.result

        switch result {
        case .failure(let error):
            #expect(error is TimeoutError)
        case .success:
            Issue.record("expected the deadline to fire")
        }

        release.signal()
        await pollUntil { discarded.value }
        #expect(discarded.value)
    }

    @Test("Work that completes before any cancel adopts the result")
    func winnerAdopts() async throws {
        let queue = DispatchQueue(label: "test.winner")
        let discarded = FlagBox()
        let value = try await runCancellableBlocking(
            on: queue,
            work: { 99 },
            discardLateResult: { _ in discarded.mark() }
        )
        #expect(value == 99)
        #expect(!discarded.value)
    }

    @Test("Racing fast work against immediate cancel never double-resumes")
    func raceNeverDoubleResumes() async {
        for _ in 0..<300 {
            let queue = DispatchQueue(label: "test.race")
            let discardCount = CountBox()
            let task = Task {
                try await runCancellableBlocking(
                    on: queue,
                    work: { 1 },
                    discardLateResult: { _ in discardCount.increment() }
                )
            }
            task.cancel()
            _ = await task.result
            #expect(discardCount.value <= 1)
        }
    }
}

private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
