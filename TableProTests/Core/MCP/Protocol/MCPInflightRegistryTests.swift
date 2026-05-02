import Foundation
@testable import TablePro
import XCTest

final class MCPInflightRegistryTests: XCTestCase {
    func testCancelByRequestIdAndSessionIdCancelsToken() async {
        let registry = MCPInflightRegistry()
        let token = MCPCancellationToken()
        let sessionId = MCPSessionId("session-1")
        let requestId = JsonRpcId.number(42)

        await registry.register(requestId: requestId, sessionId: sessionId, token: token)
        await registry.cancel(requestId: requestId, sessionId: sessionId)

        let cancelled = await token.isCancelled()
        XCTAssertTrue(cancelled)
    }

    func testRegisterSameKeyTwiceLatestWins() async {
        let registry = MCPInflightRegistry()
        let firstToken = MCPCancellationToken()
        let secondToken = MCPCancellationToken()
        let sessionId = MCPSessionId("session-2")
        let requestId = JsonRpcId.string("req-x")

        await registry.register(requestId: requestId, sessionId: sessionId, token: firstToken)
        await registry.register(requestId: requestId, sessionId: sessionId, token: secondToken)

        await registry.cancel(requestId: requestId, sessionId: sessionId)

        let firstCancelled = await firstToken.isCancelled()
        let secondCancelled = await secondToken.isCancelled()

        XCTAssertFalse(firstCancelled)
        XCTAssertTrue(secondCancelled)
    }

    func testCancelNonexistentEntryIsNoop() async {
        let registry = MCPInflightRegistry()
        let sessionId = MCPSessionId("session-3")
        let requestId = JsonRpcId.number(99)

        await registry.cancel(requestId: requestId, sessionId: sessionId)
        let count = await registry.count()
        XCTAssertEqual(count, 0)
    }

    func testRemoveDropsEntryAndSubsequentCancelIsNoop() async {
        let registry = MCPInflightRegistry()
        let token = MCPCancellationToken()
        let sessionId = MCPSessionId("session-4")
        let requestId = JsonRpcId.number(7)

        await registry.register(requestId: requestId, sessionId: sessionId, token: token)
        await registry.remove(requestId: requestId, sessionId: sessionId)

        let countAfterRemove = await registry.count()
        XCTAssertEqual(countAfterRemove, 0)

        await registry.cancel(requestId: requestId, sessionId: sessionId)
        let cancelled = await token.isCancelled()
        XCTAssertFalse(cancelled)
    }

    func testEntriesAreScopedBySessionId() async {
        let registry = MCPInflightRegistry()
        let tokenA = MCPCancellationToken()
        let tokenB = MCPCancellationToken()
        let sessionA = MCPSessionId("session-A")
        let sessionB = MCPSessionId("session-B")
        let requestId = JsonRpcId.number(1)

        await registry.register(requestId: requestId, sessionId: sessionA, token: tokenA)
        await registry.register(requestId: requestId, sessionId: sessionB, token: tokenB)

        await registry.cancel(requestId: requestId, sessionId: sessionA)

        let cancelledA = await tokenA.isCancelled()
        let cancelledB = await tokenB.isCancelled()

        XCTAssertTrue(cancelledA)
        XCTAssertFalse(cancelledB)
    }

    func testCancelAllMatchingTokenIdCancelsOnlyMatching() async {
        let registry = MCPInflightRegistry()
        let tokenA = MCPCancellationToken()
        let tokenB = MCPCancellationToken()
        let tokenC = MCPCancellationToken()
        let session = MCPSessionId("session-revoked")
        let revokedTokenId = UUID()
        let otherTokenId = UUID()

        await registry.register(
            requestId: .number(1),
            sessionId: session,
            token: tokenA,
            tokenId: revokedTokenId
        )
        await registry.register(
            requestId: .number(2),
            sessionId: session,
            token: tokenB,
            tokenId: revokedTokenId
        )
        await registry.register(
            requestId: .number(3),
            sessionId: session,
            token: tokenC,
            tokenId: otherTokenId
        )

        let cancelledSessions = await registry.cancelAll(matchingTokenId: revokedTokenId)
        XCTAssertEqual(cancelledSessions, [session])

        let cancelledA = await tokenA.isCancelled()
        let cancelledB = await tokenB.isCancelled()
        let cancelledC = await tokenC.isCancelled()
        XCTAssertTrue(cancelledA)
        XCTAssertTrue(cancelledB)
        XCTAssertFalse(cancelledC)

        let count = await registry.count()
        XCTAssertEqual(count, 1)
    }

    func testCountReflectsActiveRegistrations() async {
        let registry = MCPInflightRegistry()
        let session = MCPSessionId("session-count")

        await registry.register(
            requestId: .number(1),
            sessionId: session,
            token: MCPCancellationToken()
        )
        await registry.register(
            requestId: .number(2),
            sessionId: session,
            token: MCPCancellationToken()
        )
        await registry.register(
            requestId: .number(3),
            sessionId: session,
            token: MCPCancellationToken()
        )

        let count = await registry.count()
        XCTAssertEqual(count, 3)

        await registry.remove(requestId: .number(2), sessionId: session)
        let countAfter = await registry.count()
        XCTAssertEqual(countAfter, 2)
    }
}
