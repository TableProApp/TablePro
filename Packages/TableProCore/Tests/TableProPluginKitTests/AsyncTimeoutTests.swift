import XCTest
@testable import TableProPluginKit

final class AsyncTimeoutTests: XCTestCase {
    func testReturnsValueWhenOperationFinishesBeforeTimeout() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testThrowsTimeoutWhenOperationStalls() async {
        do {
            _ = try await withTimeout(seconds: 0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("Expected TimeoutError")
        } catch let error as TimeoutError {
            XCTAssertEqual(error.seconds, 0.05)
        } catch {
            XCTFail("Expected TimeoutError, got \(error)")
        }
    }

    func testPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await withTimeout(seconds: 5) { () -> Int in throw Boom() }
            XCTFail("Expected Boom")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("Expected Boom, got \(error)")
        }
    }

    func testOnTimeoutUnblocksCancellationDeafOperation() async {
        final class Latch: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Never>?
        }
        struct Closed: Error {}
        let latch = Latch()

        do {
            _ = try await withTimeout(
                seconds: 0.05,
                onTimeout: {
                    latch.continuation?.resume()
                    latch.continuation = nil
                }
            ) { () -> Int in
                await withCheckedContinuation { latch.continuation = $0 }
                throw Closed()
            }
            XCTFail("Expected an error")
        } catch {
            // TimeoutError or Closed both prove onTimeout unblocked the operation.
            // Without it this test hangs: the continuation ignores task
            // cancellation and the group waits for the operation child.
        }
    }

    func testOnTimeoutNotInvokedWhenOperationWins() async throws {
        final class Flag: @unchecked Sendable {
            var value = false
        }
        let flag = Flag()

        let value = try await withTimeout(seconds: 5, onTimeout: { flag.value = true }) { 42 }

        XCTAssertEqual(value, 42)
        XCTAssertFalse(flag.value)
    }
}
