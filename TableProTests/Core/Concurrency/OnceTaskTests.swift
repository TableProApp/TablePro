//
//  OnceTaskTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import XCTest

final class OnceTaskTests: XCTestCase {
    actor Counter {
        private(set) var value: Int = 0

        func increment() {
            value += 1
        }
    }

    private struct TestError: Error, Equatable {
        let tag: String
    }

    func testConcurrentSameKeyRunsWorkOnce() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()

        async let first = dedup.execute(key: "k") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return 42
        }
        async let second = dedup.execute(key: "k") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return 99
        }

        let results = try await [first, second]
        let invocations = await counter.value

        XCTAssertEqual(invocations, 1, "Work block must run exactly once for concurrent same-key callers")
        XCTAssertEqual(results[0], results[1], "Concurrent callers must observe the same value")
        XCTAssertEqual(results[0], 42, "Both callers must receive the value produced by the first work block")
    }

    func testConcurrentDifferentKeysRunWorkSeparately() async throws {
        let dedup = OnceTask<String, String>()
        let counter = Counter()

        async let alpha = dedup.execute(key: "alpha") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return "alpha-value"
        }
        async let beta = dedup.execute(key: "beta") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return "beta-value"
        }

        let alphaValue = try await alpha
        let betaValue = try await beta
        let invocations = await counter.value

        XCTAssertEqual(invocations, 2, "Distinct keys must each run their own work block")
        XCTAssertEqual(alphaValue, "alpha-value")
        XCTAssertEqual(betaValue, "beta-value")
    }

    func testThrowingWorkPropagatesAndClearsInFlight() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()

        do {
            _ = try await dedup.execute(key: "k") {
                await counter.increment()
                throw TestError(tag: "first")
            }
            XCTFail("Expected throw from first execute")
        } catch let error as TestError {
            XCTAssertEqual(error.tag, "first")
        }

        let secondValue = try await dedup.execute(key: "k") {
            await counter.increment()
            return 7
        }

        XCTAssertEqual(secondValue, 7, "After a throw, the next execute must rerun the work")
        let invocations = await counter.value
        XCTAssertEqual(invocations, 2, "Both work blocks must have run (throw cleared the in-flight slot)")
    }

    func testCancelKeyClearsInFlightAndAllowsRerun() async throws {
        let dedup = OnceTask<String, Int>()
        let counter = Counter()
        let started = expectation(description: "work started")
        started.assertForOverFulfill = false

        let inFlight = Task {
            try await dedup.execute(key: "k") {
                await counter.increment()
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }

        await fulfillment(of: [started], timeout: 2.0)
        await dedup.cancel(key: "k")

        do {
            _ = try await inFlight.value
            XCTFail("Expected CancellationError from cancelled in-flight call")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let rerunValue = try await dedup.execute(key: "k") {
            await counter.increment()
            return 11
        }

        XCTAssertEqual(rerunValue, 11, "After cancel, a fresh execute must run the work again")
        let invocations = await counter.value
        XCTAssertEqual(invocations, 2)
    }

    func testSequentialSameKeyRunsWorkAgain() async throws {
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

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        let invocations = await counter.value
        XCTAssertEqual(invocations, 2, "Sequential calls (after first completes) must each run the work")
    }

    func testCancelAllCancelsEveryInFlight() async throws {
        let dedup = OnceTask<String, Int>()
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        firstStarted.assertForOverFulfill = false
        secondStarted.assertForOverFulfill = false

        let firstTask = Task {
            try await dedup.execute(key: "a") {
                firstStarted.fulfill()
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        let secondTask = Task {
            try await dedup.execute(key: "b") {
                secondStarted.fulfill()
                try await Task.sleep(for: .seconds(5))
                return 2
            }
        }

        await fulfillment(of: [firstStarted, secondStarted], timeout: 2.0)
        await dedup.cancelAll()

        for task in [firstTask, secondTask] {
            do {
                _ = try await task.value
                XCTFail("Expected CancellationError from cancelAll")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
        }
    }
}
