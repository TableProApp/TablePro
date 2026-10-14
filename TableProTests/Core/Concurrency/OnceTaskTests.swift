import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct OnceTaskTests {
    actor Counter {
        private(set) var value: Int = 0

        func increment() {
            value += 1
        }
    }

    private struct TestError: Error, Equatable {
        let tag: String
    }

    @Test
    func rerunDoesNotAdoptAbandonedNonCooperativeWork() async throws {
        let dedup = OnceTask<String, Int>()
        let started = AsyncGate()
        // Ignores cancellation, standing in for a driver blocked in a C call.
        let release = AsyncGate()

        let abandoned = Task {
            try await dedup.execute(key: "k") {
                await started.open()
                await release.wait()
                return 1
            }
        }

        await started.wait()
        await dedup.cancel(key: "k")

        let rerunValue = try await dedup.execute(key: "k") { 2 }
        #expect(rerunValue == 2, "A rerun must run fresh work, not adopt the abandoned attempt")

        await release.open()
        let abandonedValue = try await abandoned.value
        #expect(abandonedValue == 1, "The abandoned attempt still completes; its result belongs to no one")
    }

    @Test
    func concurrentSameKeyRunsWorkOnce() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()
        let firstRegistered = AsyncGate()

        let firstTask = Task {
            try await dedup.execute(key: "k") {
                await counter.increment()
                await firstRegistered.open()
                // Keeps the first call in flight while the second arrives; nothing marks that arrival.
                try await Task.sleep(for: .milliseconds(200))
                return 42
            }
        }

        await firstRegistered.wait()

        let second = try await dedup.execute(key: "k") {
            await counter.increment()
            return 99
        }
        let first = try await firstTask.value
        let invocations = await counter.value

        #expect(invocations == 1, "Work block must run exactly once for concurrent same-key callers")
        #expect(first == second, "Concurrent callers must observe the same value")
        #expect(first == 42, "Both callers must receive the value produced by the first work block")
    }

    /// Each block finishes only once the other has started, so both are in flight together.
    @Test(.timeLimit(.minutes(1)))
    func concurrentDifferentKeysRunWorkSeparately() async throws {
        let dedup = OnceTask<String, String>()
        let counter = Counter()
        let alphaStarted = AsyncGate()
        let betaStarted = AsyncGate()

        async let alpha = dedup.execute(key: "alpha") {
            await counter.increment()
            await alphaStarted.open()
            await betaStarted.wait()
            return "alpha-value"
        }
        async let beta = dedup.execute(key: "beta") {
            await counter.increment()
            await betaStarted.open()
            await alphaStarted.wait()
            return "beta-value"
        }

        let alphaValue = try await alpha
        let betaValue = try await beta
        let invocations = await counter.value

        #expect(invocations == 2, "Distinct keys must each run their own work block")
        #expect(alphaValue == "alpha-value")
        #expect(betaValue == "beta-value")
    }

    @Test
    func throwingWorkPropagatesAndClearsInFlight() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()

        do {
            _ = try await dedup.execute(key: "k") {
                await counter.increment()
                throw TestError(tag: "first")
            }
            Issue.record("Expected throw from first execute")
        } catch let error as TestError {
            #expect(error.tag == "first")
        }

        let secondValue = try await dedup.execute(key: "k") {
            await counter.increment()
            return 7
        }

        #expect(secondValue == 7, "After a throw, the next execute must rerun the work")
        let invocations = await counter.value
        #expect(invocations == 2, "Both work blocks must have run (throw cleared the in-flight slot)")
    }

    @Test
    func cancelKeyClearsInFlightAndAllowsRerun() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()
        let started = AsyncGate()

        let inFlight = Task {
            try await dedup.execute(key: "k") {
                await counter.increment()
                await started.open()
                // Parks until the cancel ends the sleep.
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }

        await started.wait()
        await dedup.cancel(key: "k")

        await #expect(throws: CancellationError.self, "Expected CancellationError from cancelled in-flight call") {
            try await inFlight.value
        }

        let rerunValue = try await dedup.execute(key: "k") {
            await counter.increment()
            return 11
        }

        #expect(rerunValue == 11, "After cancel, a fresh execute must run the work again")
        let invocations = await counter.value
        #expect(invocations == 2)
    }

    @Test
    func sequentialSameKeyRunsWorkAgain() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()

        let first = try await dedup.execute(key: "k") {
            await counter.increment()
            return 1
        }
        let second = try await dedup.execute(key: "k") {
            await counter.increment()
            return 2
        }

        #expect(first == 1)
        #expect(second == 2)
        let invocations = await counter.value
        #expect(invocations == 2, "Sequential calls (after first completes) must each run the work")
    }

    @Test
    func cancelAllCancelsEveryInFlight() async throws {
        let dedup = OnceTask<String, Int>()
        let firstStarted = AsyncGate()
        let secondStarted = AsyncGate()

        let firstTask = Task {
            try await dedup.execute(key: "a") {
                await firstStarted.open()
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        let secondTask = Task {
            try await dedup.execute(key: "b") {
                await secondStarted.open()
                try await Task.sleep(for: .seconds(5))
                return 2
            }
        }

        await firstStarted.wait()
        await secondStarted.wait()
        await dedup.cancelAll()

        for task in [firstTask, secondTask] {
            await #expect(throws: CancellationError.self, "Expected CancellationError from cancelAll") {
                try await task.value
            }
        }
    }
}
