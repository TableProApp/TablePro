import XCTest
@testable import TableProOracleCore

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
