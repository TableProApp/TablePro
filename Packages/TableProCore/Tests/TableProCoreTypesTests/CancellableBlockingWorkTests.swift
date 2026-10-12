import Foundation
@testable import TableProCoreTypes
import Testing

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

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private struct TimeoutError: Error {}

private enum TestWatchdog {
    private final class FirstArrival<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = continuation
        }

        func claim() -> CheckedContinuation<Value?, Never>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }

    static func result<Value: Sendable>(
        within timeout: Duration = .seconds(2),
        of work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let arrival = FirstArrival(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                arrival.claim()?.resume(returning: nil)
            }
            Task {
                let value = await work()
                arrival.claim()?.resume(returning: value)
                timer.cancel()
            }
        }
    }
}

@Suite("Cancellable blocking work")
struct CancellableBlockingWorkTests {
    @Test("Work that completes normally returns its value")
    func normalCompletion() async throws {
        let queue = DispatchQueue(label: "test.normal")
        let value = try await runCancellableBlocking(on: queue, work: { 42 })
        #expect(value == 42)
    }

    @Test("Cancel returns promptly and the late result is discarded, not adopted")
    func cancelDiscardsLateResult() async throws {
        let queue = DispatchQueue(label: "test.cancel")
        let workStarted = FlagBox()
        let release = DispatchSemaphore(value: 0)
        let discarded = FlagBox()

        let task = Task {
            try await runCancellableBlocking(
                on: queue,
                work: { () -> Int in
                    workStarted.mark()
                    release.wait()
                    return 7
                },
                discardLateResult: { _ in discarded.mark() }
            )
        }
        var didRelease = false
        defer {
            task.cancel()
            if !didRelease { release.signal() }
        }

        try #require(await waitUntil { workStarted.value })
        task.cancel()

        let result = try #require(await TestWatchdog.result { await task.result })
        switch result {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            Issue.record("Expected the cancelled caller to throw")
        }
        #expect(!discarded.value)

        didRelease = true
        release.signal()
        #expect(await waitUntil { discarded.value })
    }

    @Test("A deadline fails the caller and discards the late result")
    func deadlineFires() async throws {
        let queue = DispatchQueue(label: "test.deadline")
        let release = DispatchSemaphore(value: 0)
        let discarded = FlagBox()

        let task = Task {
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
        }
        var didRelease = false
        defer {
            task.cancel()
            if !didRelease { release.signal() }
        }

        let result = try #require(await TestWatchdog.result { await task.result })

        switch result {
        case .failure(let error):
            #expect(error is TimeoutError)
        case .success:
            Issue.record("Expected the deadline to fire")
        }

        didRelease = true
        release.signal()
        #expect(await waitUntil { discarded.value })
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

    @Test("A gate reports itself settled once the caller has an answer, whichever side gave it")
    func gateReportsSettled() {
        let won = SingleResumeGate<Int>()
        #expect(!won.isSettled)
        #expect(won.win(1))
        #expect(won.isSettled)
        #expect(!won.fail(CancellationError()))

        let failed = SingleResumeGate<Int>()
        #expect(failed.fail(CancellationError()))
        #expect(failed.isSettled)
        #expect(!failed.win(1))
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
