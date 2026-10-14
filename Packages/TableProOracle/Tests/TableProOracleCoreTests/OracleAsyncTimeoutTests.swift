@testable import TableProOracleCore
import XCTest

final class OracleAsyncTimeoutTests: XCTestCase {
    func testOperationCompletingBeforeDeadlineReturnsItsValue() async throws {
        let result = try await withOracleTimeout(seconds: 5) { "done" }
        XCTAssertEqual(result, "done")
    }

    func testOperationCompletingBeforeDeadlineNeverCallsOnTimeout() async throws {
        let timeoutCount = Counter()
        let result = try await withOracleTimeout(
            seconds: 5,
            onTimeout: { timeoutCount.increment() },
            operation: { 42 }
        )
        XCTAssertEqual(result, 42)
        XCTAssertEqual(timeoutCount.value, 0)
    }

    func testOperationExceedingDeadlineThrowsTimeoutAndCallsOnTimeoutOnce() async {
        let timeoutCount = Counter()
        do {
            _ = try await withOracleTimeout(
                seconds: 0.05,
                onTimeout: { timeoutCount.increment() },
                operation: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "never"
                }
            )
            XCTFail("expected the deadline to fire")
        } catch let error as OracleTimeoutError {
            XCTAssertEqual(error.seconds, 0.05)
        } catch {
            XCTFail("expected OracleTimeoutError, got \(error)")
        }
        XCTAssertEqual(timeoutCount.value, 1)
    }

    /// The task group waits for the operation child even after the deadline
    /// fires, so an `onTimeout` that does not force the operation to finish
    /// leaves the caller blocked past its own deadline.
    func testOnTimeoutMustUnblockAnOperationThatIgnoresCancellation() async {
        let release = DispatchSemaphore(value: 0)
        let released = Counter()

        _ = try? await withOracleTimeout(
            seconds: 0.05,
            onTimeout: { release.signal() },
            operation: {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        if release.wait(timeout: .now() + 5) == .success {
                            released.increment()
                        }
                        continuation.resume()
                    }
                }
                return "ignored"
            }
        )

        XCTAssertEqual(
            released.value,
            1,
            "onTimeout must release an operation that ignores cancellation, or the task group never unwinds"
        )
    }

    /// A login does not observe task cancellation, so it can finish after its caller gave up. That
    /// session reaches nobody, and only `onAbandoned` can close it.
    func testValueArrivingAfterCancellationGoesToOnAbandoned() async {
        let abandoned = Counter()
        let task = Task {
            try await withOracleTimeout(
                seconds: 5,
                onTimeout: {},
                onAbandoned: { _ in abandoned.increment() },
                operation: {
                    await finishIgnoringCancellation(after: .milliseconds(200))
                    return "late"
                }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        switch await task.result {
        case .success:
            XCTFail("a cancelled call must not return the late value")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertEqual(abandoned.value, 1)
    }

    func testValueArrivingAfterTheDeadlineGoesToOnAbandoned() async {
        let abandoned = Counter()
        do {
            _ = try await withOracleTimeout(
                seconds: 0.05,
                onTimeout: {},
                onAbandoned: { _ in abandoned.increment() },
                operation: {
                    await finishIgnoringCancellation(after: .milliseconds(300))
                    return "late"
                }
            )
            XCTFail("expected the deadline to fire")
        } catch {
            XCTAssertTrue(error is OracleTimeoutError, "expected OracleTimeoutError, got \(error)")
        }
        XCTAssertEqual(abandoned.value, 1)
    }

    func testValueReturnedInTimeIsNotAbandoned() async throws {
        let abandoned = Counter()
        let result = try await withOracleTimeout(
            seconds: 5,
            onTimeout: {},
            onAbandoned: { _ in abandoned.increment() },
            operation: { "done" }
        )
        XCTAssertEqual(result, "done")
        XCTAssertEqual(abandoned.value, 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func finishIgnoringCancellation(after delay: DispatchTimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            continuation.resume()
        }
    }
}
