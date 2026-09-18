import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPCancellationTokenTests: XCTestCase {
    func testNewTokenIsNotCancelled() async {
        let token = MCPCancellationToken()
        let cancelled = await token.isCancelled
        let reason = await token.reason
        XCTAssertFalse(cancelled)
        XCTAssertNil(reason)
    }

    func testCancelRecordsTheReason() async {
        let token = MCPCancellationToken()
        await token.cancel(reason: .clientDisconnected)

        let cancelled = await token.isCancelled
        let reason = await token.reason
        XCTAssertTrue(cancelled)
        XCTAssertEqual(reason, .clientDisconnected)
    }

    func testCancelDefaultsToAClientRequest() async {
        let token = MCPCancellationToken()
        await token.cancel()

        let reason = await token.reason
        XCTAssertEqual(reason, .clientRequested(nil))
    }

    func testCancelIsIdempotentAndKeepsTheFirstReason() async {
        let token = MCPCancellationToken()
        let flag = ObservedFlag()
        await token.onCancel { _ in await flag.set() }

        await token.cancel(reason: .clientRequested("user pressed stop"))
        await token.cancel(reason: .serverShuttingDown)
        await token.cancel(reason: .deadlineExceeded)

        let reason = await token.reason
        let handlerRuns = await flag.times()
        XCTAssertEqual(reason, .clientRequested("user pressed stop"))
        XCTAssertEqual(handlerRuns, 1)
    }

    func testOnCancelHandlersRunWhenCancelFires() async {
        let token = MCPCancellationToken()
        let first = ObservedFlag()
        let second = ObservedFlag()
        await token.onCancel { _ in await first.set() }
        await token.onCancel { _ in await second.set() }

        let beforeFirst = await first.value()
        let beforeSecond = await second.value()
        XCTAssertFalse(beforeFirst)
        XCTAssertFalse(beforeSecond)

        await token.cancel(reason: .credentialRevoked)

        let afterFirst = await first.value()
        let afterSecond = await second.value()
        XCTAssertTrue(afterFirst)
        XCTAssertTrue(afterSecond)
    }

    func testHandlersReceiveTheCancellationReason() async {
        let token = MCPCancellationToken()
        let observed = ObservedValue<MCPCancellationReason>()
        await token.onCancel { reason in await observed.set(reason) }

        await token.cancel(reason: .deadlineExceeded)

        let reason = await observed.value()
        XCTAssertEqual(reason, .deadlineExceeded)
    }

    func testHandlerRegisteredAfterCancellationRunsImmediately() async {
        let token = MCPCancellationToken()
        await token.cancel(reason: .serverShuttingDown)

        let observed = ObservedValue<MCPCancellationReason>()
        await token.onCancel { reason in await observed.set(reason) }

        let reason = await observed.value()
        XCTAssertEqual(reason, .serverShuttingDown)
    }

    func testThrowIfCancelledOnlyThrowsAfterCancellation() async throws {
        let token = MCPCancellationToken()
        try await token.throwIfCancelled()

        await token.cancel(reason: .clientDisconnected)

        do {
            try await token.throwIfCancelled()
            XCTFail("Expected a CancellationError")
        } catch is CancellationError {
            return
        }
    }

    func testEveryReasonHasAStableLabel() {
        XCTAssertEqual(MCPCancellationReason.clientRequested(nil).label, "client_requested")
        XCTAssertEqual(MCPCancellationReason.clientRequested("stop").label, "client_requested")
        XCTAssertEqual(MCPCancellationReason.clientDisconnected.label, "client_disconnected")
        XCTAssertEqual(MCPCancellationReason.deadlineExceeded.label, "deadline_exceeded")
        XCTAssertEqual(MCPCancellationReason.credentialRevoked.label, "credential_revoked")
        XCTAssertEqual(MCPCancellationReason.serverShuttingDown.label, "server_shutting_down")
    }
}
