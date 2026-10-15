import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import Testing

struct MCPCancellationTokenTests {
    @Test func testNewTokenIsNotCancelled() async {
        let token = MCPCancellationToken()
        let cancelled = await token.isCancelled
        let reason = await token.reason
        #expect(!cancelled)
        #expect(reason == nil)
    }

    @Test func testCancelRecordsTheReason() async {
        let token = MCPCancellationToken()
        await token.cancel(reason: .clientDisconnected)

        let cancelled = await token.isCancelled
        let reason = await token.reason
        #expect(cancelled)
        #expect(reason == .clientDisconnected)
    }

    @Test func testCancelDefaultsToAClientRequest() async {
        let token = MCPCancellationToken()
        await token.cancel()

        let reason = await token.reason
        #expect(reason == .clientRequested(nil))
    }

    @Test func testCancelIsIdempotentAndKeepsTheFirstReason() async {
        let token = MCPCancellationToken()
        let flag = ObservedFlag()
        await token.onCancel { _ in await flag.set() }

        await token.cancel(reason: .clientRequested("user pressed stop"))
        await token.cancel(reason: .serverShuttingDown)
        await token.cancel(reason: .deadlineExceeded)

        let reason = await token.reason
        let handlerRuns = await flag.times()
        #expect(reason == .clientRequested("user pressed stop"))
        #expect(handlerRuns == 1)
    }

    @Test func testOnCancelHandlersRunWhenCancelFires() async {
        let token = MCPCancellationToken()
        let first = ObservedFlag()
        let second = ObservedFlag()
        await token.onCancel { _ in await first.set() }
        await token.onCancel { _ in await second.set() }

        let beforeFirst = await first.value()
        let beforeSecond = await second.value()
        #expect(!beforeFirst)
        #expect(!beforeSecond)

        await token.cancel(reason: .credentialRevoked)

        let afterFirst = await first.value()
        let afterSecond = await second.value()
        #expect(afterFirst)
        #expect(afterSecond)
    }

    @Test func testHandlersReceiveTheCancellationReason() async {
        let token = MCPCancellationToken()
        let observed = ObservedValue<MCPCancellationReason>()
        await token.onCancel { reason in await observed.set(reason) }

        await token.cancel(reason: .deadlineExceeded)

        let reason = await observed.value()
        #expect(reason == .deadlineExceeded)
    }

    @Test func testHandlerRegisteredAfterCancellationRunsImmediately() async {
        let token = MCPCancellationToken()
        await token.cancel(reason: .serverShuttingDown)

        let observed = ObservedValue<MCPCancellationReason>()
        await token.onCancel { reason in await observed.set(reason) }

        let reason = await observed.value()
        #expect(reason == .serverShuttingDown)
    }

    @Test func testThrowIfCancelledOnlyThrowsAfterCancellation() async throws {
        let token = MCPCancellationToken()
        try await token.throwIfCancelled()

        await token.cancel(reason: .clientDisconnected)

        do {
            try await token.throwIfCancelled()
            Issue.record("Expected a CancellationError")
        } catch is CancellationError {
            return
        }
    }

    @Test func testEveryReasonHasAStableLabel() {
        #expect(MCPCancellationReason.clientRequested(nil).label == "client_requested")
        #expect(MCPCancellationReason.clientRequested("stop").label == "client_requested")
        #expect(MCPCancellationReason.clientDisconnected.label == "client_disconnected")
        #expect(MCPCancellationReason.deadlineExceeded.label == "deadline_exceeded")
        #expect(MCPCancellationReason.credentialRevoked.label == "credential_revoked")
        #expect(MCPCancellationReason.serverShuttingDown.label == "server_shutting_down")
    }
}
