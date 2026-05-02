import Foundation
@testable import TablePro
import XCTest

final class MCPCancellationTokenTests: XCTestCase {
    func testNewTokenIsNotCancelled() async {
        let token = MCPCancellationToken()
        let cancelled = await token.isCancelled()
        XCTAssertFalse(cancelled)
    }

    func testIsCancelledAfterCancel() async {
        let token = MCPCancellationToken()
        await token.cancel()
        let cancelled = await token.isCancelled()
        XCTAssertTrue(cancelled)
    }

    func testOnCancelHandlerRunsWhenCancelFires() async {
        let token = MCPCancellationToken()
        let flag = ObservedFlag()
        await token.onCancel {
            await flag.set()
        }

        let beforeCancel = await flag.value()
        XCTAssertFalse(beforeCancel)

        await token.cancel()

        let afterCancel = await flag.value()
        XCTAssertTrue(afterCancel)
    }

    func testOnCancelRegisteredAfterCancelRunsImmediately() async {
        let token = MCPCancellationToken()
        await token.cancel()

        let flag = ObservedFlag()
        await token.onCancel {
            await flag.set()
        }

        let value = await flag.value()
        XCTAssertTrue(value)
    }

    func testMultipleOnCancelHandlersAllInvoked() async {
        let token = MCPCancellationToken()
        let flagA = ObservedFlag()
        let flagB = ObservedFlag()
        let flagC = ObservedFlag()

        await token.onCancel { await flagA.set() }
        await token.onCancel { await flagB.set() }
        await token.onCancel { await flagC.set() }

        await token.cancel()

        let valueA = await flagA.value()
        let valueB = await flagB.value()
        let valueC = await flagC.value()
        XCTAssertTrue(valueA)
        XCTAssertTrue(valueB)
        XCTAssertTrue(valueC)
    }

    func testCancelTwiceIsIdempotent() async {
        let token = MCPCancellationToken()
        let counter = HandlerInvocationCounter()
        await token.onCancel {
            await counter.increment()
        }

        await token.cancel()
        await token.cancel()

        let count = await counter.value()
        XCTAssertEqual(count, 1)

        let cancelled = await token.isCancelled()
        XCTAssertTrue(cancelled)
    }

    func testThrowIfCancelledThrowsAfterCancel() async {
        let token = MCPCancellationToken()
        await token.cancel()
        do {
            try await token.throwIfCancelled()
            XCTFail("Expected CancellationError to be thrown")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testThrowIfCancelledDoesNotThrowWhenNotCancelled() async {
        let token = MCPCancellationToken()
        do {
            try await token.throwIfCancelled()
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor HandlerInvocationCounter {
    private var invocations: Int = 0

    func increment() {
        invocations += 1
    }

    func value() -> Int {
        invocations
    }
}
