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
}
