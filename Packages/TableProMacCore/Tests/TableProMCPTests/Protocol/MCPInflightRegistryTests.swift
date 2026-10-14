import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPInflightRegistryTests: XCTestCase {
    private static let aliceTokenId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001") ?? UUID()
    private static let bobTokenId = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002") ?? UUID()

    private let alice = MCPProtocolTestSupport.makePrincipal(
        fingerprint: "alice",
        tokenId: MCPInflightRegistryTests.aliceTokenId
    )
    private let bob = MCPProtocolTestSupport.makePrincipal(
        fingerprint: "bob",
        tokenId: MCPInflightRegistryTests.bobTokenId
    )

    func testCancelCancelsTheRegisteredToken() async {
        let registry = MCPInflightRegistry()
        let token = MCPCancellationToken()
        let key = MCPInflightKey(principal: alice, requestId: .number(42))

        await registry.register(key: key, token: token, tokenId: alice.tokenId, method: "tools/call", startedAt: .now)
        let cancelled = await registry.cancel(key: key, reason: .clientRequested("stop"))

        XCTAssertTrue(cancelled)
        let tokenCancelled = await token.isCancelled
        let reason = await token.reason
        XCTAssertTrue(tokenCancelled)
        XCTAssertEqual(reason, .clientRequested("stop"))
    }

    func testTheSameRequestIdFromTwoPrincipalsIsTwoEntries() async {
        let registry = MCPInflightRegistry()
        let aliceToken = MCPCancellationToken()
        let bobToken = MCPCancellationToken()
        let requestId = JsonRpcId.number(1)
        let aliceKey = MCPInflightKey(principal: alice, requestId: requestId)
        let bobKey = MCPInflightKey(principal: bob, requestId: requestId)

        XCTAssertNotEqual(aliceKey, bobKey)

        let aliceRegistered = await registry.register(
            key: aliceKey,
            token: aliceToken,
            tokenId: alice.tokenId,
            method: "tools/call",
            startedAt: .now
        )
        let bobRegistered = await registry.register(
            key: bobKey,
            token: bobToken,
            tokenId: bob.tokenId,
            method: "tools/call",
            startedAt: .now
        )
        XCTAssertTrue(aliceRegistered)
        XCTAssertTrue(bobRegistered)

        let count = await registry.count()
        XCTAssertEqual(count, 2)

        await registry.cancel(key: aliceKey, reason: .clientRequested(nil))

        let aliceCancelled = await aliceToken.isCancelled
        let bobCancelled = await bobToken.isCancelled
        XCTAssertTrue(aliceCancelled)
        XCTAssertFalse(bobCancelled)

        let remaining = await registry.contains(key: bobKey)
        XCTAssertTrue(remaining)
    }

    func testReusingAnInFlightRequestIdReportsTheDisplacement() async {
        let registry = MCPInflightRegistry()
        let first = MCPCancellationToken()
        let second = MCPCancellationToken()
        let key = MCPInflightKey(principal: alice, requestId: .string("req-x"))

        let firstRegistered = await registry.register(
            key: key,
            token: first,
            tokenId: alice.tokenId,
            method: "tools/call",
            startedAt: .now
        )
        let secondRegistered = await registry.register(
            key: key,
            token: second,
            tokenId: alice.tokenId,
            method: "tools/call",
            startedAt: .now
        )
        XCTAssertTrue(firstRegistered)
        XCTAssertFalse(secondRegistered)

        await registry.cancel(key: key, reason: .clientRequested(nil))

        let firstCancelled = await first.isCancelled
        let secondCancelled = await second.isCancelled
        XCTAssertFalse(firstCancelled)
        XCTAssertTrue(secondCancelled)
    }

    func testRemovingWithAStaleTokenLeavesTheEntryAlone() async {
        let registry = MCPInflightRegistry()
        let stale = MCPCancellationToken()
        let live = MCPCancellationToken()
        let key = MCPInflightKey(principal: alice, requestId: .number(3))

        await registry.register(key: key, token: stale, tokenId: nil, method: "tools/call", startedAt: .now)
        await registry.register(key: key, token: live, tokenId: nil, method: "tools/call", startedAt: .now)
        await registry.remove(key: key, token: stale)

        let stillThere = await registry.contains(key: key)
        XCTAssertTrue(stillThere)

        await registry.remove(key: key, token: live)
        let gone = await registry.contains(key: key)
        XCTAssertFalse(gone)
    }

    func testCancellingAnEntryThatIsNotInFlightIsANoop() async {
        let registry = MCPInflightRegistry()
        let key = MCPInflightKey(principal: alice, requestId: .number(7))

        let cancelled = await registry.cancel(key: key, reason: .clientRequested(nil))
        XCTAssertFalse(cancelled)

        let count = await registry.count()
        XCTAssertEqual(count, 0)
    }

    func testCancellingTwiceOnlyReportsTheFirstCancellation() async {
        let registry = MCPInflightRegistry()
        let key = MCPInflightKey(principal: alice, requestId: .number(9))
        await registry.register(
            key: key,
            token: MCPCancellationToken(),
            tokenId: nil,
            method: "tools/call",
            startedAt: .now
        )

        let first = await registry.cancel(key: key, reason: .clientRequested(nil))
        let second = await registry.cancel(key: key, reason: .clientRequested(nil))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testRevokingATokenCancelsOnlyThatTokensRequests() async {
        let registry = MCPInflightRegistry()
        let aliceToken = MCPCancellationToken()
        let bobToken = MCPCancellationToken()
        let aliceKey = MCPInflightKey(principal: alice, requestId: .number(1))
        let bobKey = MCPInflightKey(principal: bob, requestId: .number(2))

        await registry.register(
            key: aliceKey,
            token: aliceToken,
            tokenId: alice.tokenId,
            method: "tools/call",
            startedAt: .now
        )
        await registry.register(
            key: bobKey,
            token: bobToken,
            tokenId: bob.tokenId,
            method: "tools/call",
            startedAt: .now
        )

        let cancelledCount = await registry.cancelAll(
            matchingTokenId: Self.aliceTokenId,
            reason: .credentialRevoked
        )
        XCTAssertEqual(cancelledCount, 1)

        let aliceCancelled = await aliceToken.isCancelled
        let bobCancelled = await bobToken.isCancelled
        let aliceReason = await aliceToken.reason
        XCTAssertTrue(aliceCancelled)
        XCTAssertFalse(bobCancelled)
        XCTAssertEqual(aliceReason, .credentialRevoked)
    }

    func testCancellingByFingerprintCancelsEveryRequestOfThatClient() async {
        let registry = MCPInflightRegistry()
        let firstToken = MCPCancellationToken()
        let secondToken = MCPCancellationToken()
        let otherToken = MCPCancellationToken()

        await registry.register(
            key: MCPInflightKey(principal: alice, requestId: .number(1)),
            token: firstToken,
            tokenId: alice.tokenId,
            method: "tools/call",
            startedAt: .now
        )
        await registry.register(
            key: MCPInflightKey(principal: alice, requestId: .number(2)),
            token: secondToken,
            tokenId: alice.tokenId,
            method: "tools/list",
            startedAt: .now
        )
        await registry.register(
            key: MCPInflightKey(principal: bob, requestId: .number(3)),
            token: otherToken,
            tokenId: bob.tokenId,
            method: "tools/list",
            startedAt: .now
        )

        let cancelled = await registry.cancelAll(
            matchingFingerprint: alice.tokenFingerprint,
            reason: .serverShuttingDown
        )
        XCTAssertEqual(cancelled, 2)

        let remaining = await registry.count()
        XCTAssertEqual(remaining, 1)

        let otherCancelled = await otherToken.isCancelled
        XCTAssertFalse(otherCancelled)
    }

    func testShutdownCancelsEverythingAndEmptiesTheRegistry() async {
        let registry = MCPInflightRegistry()
        for index in 1 ... 3 {
            await registry.register(
                key: MCPInflightKey(principal: alice, requestId: .number(Int64(index))),
                token: MCPCancellationToken(),
                tokenId: alice.tokenId,
                method: "tools/call",
                startedAt: .now
            )
        }

        let cancelled = await registry.cancelAll(reason: .serverShuttingDown)
        XCTAssertEqual(cancelled, 3)

        let count = await registry.count()
        XCTAssertEqual(count, 0)
    }

    func testKeyIsBuiltFromTheClientFingerprint() {
        let key = MCPInflightKey(principal: alice, requestId: .string("abc"))
        XCTAssertEqual(key.clientFingerprint, alice.tokenFingerprint)
        XCTAssertEqual(key.requestId, .string("abc"))
        XCTAssertEqual(key, MCPInflightKey(clientFingerprint: "alice", requestId: .string("abc")))
    }
}
