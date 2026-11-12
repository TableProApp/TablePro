import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import Testing

struct MCPInflightRegistryTests {
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

    @Test func testCancelCancelsTheRegisteredToken() async {
        let registry = MCPInflightRegistry()
        let token = MCPCancellationToken()
        let key = MCPInflightKey(principal: alice, requestId: .number(42))

        await registry.register(key: key, token: token, tokenId: alice.tokenId, method: "tools/call", startedAt: .now)
        let cancelled = await registry.cancel(key: key, reason: .clientRequested("stop"))

        #expect(cancelled)
        let tokenCancelled = await token.isCancelled
        let reason = await token.reason
        #expect(tokenCancelled)
        #expect(reason == .clientRequested("stop"))
    }

    @Test func testTheSameRequestIdFromTwoPrincipalsIsTwoEntries() async {
        let registry = MCPInflightRegistry()
        let aliceToken = MCPCancellationToken()
        let bobToken = MCPCancellationToken()
        let requestId = JsonRpcId.number(1)
        let aliceKey = MCPInflightKey(principal: alice, requestId: requestId)
        let bobKey = MCPInflightKey(principal: bob, requestId: requestId)

        #expect(aliceKey != bobKey)

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
        #expect(aliceRegistered)
        #expect(bobRegistered)

        let count = await registry.count()
        #expect(count == 2)

        await registry.cancel(key: aliceKey, reason: .clientRequested(nil))

        let aliceCancelled = await aliceToken.isCancelled
        let bobCancelled = await bobToken.isCancelled
        #expect(aliceCancelled)
        #expect(!bobCancelled)

        let remaining = await registry.contains(key: bobKey)
        #expect(remaining)
    }

    @Test func testReusingAnInFlightRequestIdReportsTheDisplacement() async {
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
        #expect(firstRegistered)
        #expect(!secondRegistered)

        await registry.cancel(key: key, reason: .clientRequested(nil))

        let firstCancelled = await first.isCancelled
        let secondCancelled = await second.isCancelled
        #expect(!firstCancelled)
        #expect(secondCancelled)
    }

    @Test func testRemovingWithAStaleTokenLeavesTheEntryAlone() async {
        let registry = MCPInflightRegistry()
        let stale = MCPCancellationToken()
        let live = MCPCancellationToken()
        let key = MCPInflightKey(principal: alice, requestId: .number(3))

        await registry.register(key: key, token: stale, tokenId: nil, method: "tools/call", startedAt: .now)
        await registry.register(key: key, token: live, tokenId: nil, method: "tools/call", startedAt: .now)
        await registry.remove(key: key, token: stale)

        let stillThere = await registry.contains(key: key)
        #expect(stillThere)

        await registry.remove(key: key, token: live)
        let gone = await registry.contains(key: key)
        #expect(!gone)
    }

    @Test func testCancellingAnEntryThatIsNotInFlightIsANoop() async {
        let registry = MCPInflightRegistry()
        let key = MCPInflightKey(principal: alice, requestId: .number(7))

        let cancelled = await registry.cancel(key: key, reason: .clientRequested(nil))
        #expect(!cancelled)

        let count = await registry.count()
        #expect(count == 0)
    }

    @Test func testCancellingTwiceOnlyReportsTheFirstCancellation() async {
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
        #expect(first)
        #expect(!second)
    }

    @Test func testRevokingATokenCancelsOnlyThatTokensRequests() async {
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
        #expect(cancelledCount == 1)

        let aliceCancelled = await aliceToken.isCancelled
        let bobCancelled = await bobToken.isCancelled
        let aliceReason = await aliceToken.reason
        #expect(aliceCancelled)
        #expect(!bobCancelled)
        #expect(aliceReason == .credentialRevoked)
    }

    @Test func testCancellingByFingerprintCancelsEveryRequestOfThatClient() async {
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
        #expect(cancelled == 2)

        let remaining = await registry.count()
        #expect(remaining == 1)

        let otherCancelled = await otherToken.isCancelled
        #expect(!otherCancelled)
    }

    @Test func testShutdownCancelsEverythingAndEmptiesTheRegistry() async {
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
        #expect(cancelled == 3)

        let count = await registry.count()
        #expect(count == 0)
    }

    @Test func testKeyIsBuiltFromTheClientFingerprint() {
        let key = MCPInflightKey(principal: alice, requestId: .string("abc"))
        #expect(key.clientFingerprint == alice.tokenFingerprint)
        #expect(key.requestId == .string("abc"))
        #expect(key == MCPInflightKey(clientFingerprint: "alice", requestId: .string("abc")))
    }

    @Test("Two stdio clients on the bridge credential keep one request id apart")
    func stdioClientsSharingTheBridgeCredentialAreTwoEntries() async {
        let registry = MCPInflightRegistry()
        let cursorToken = MCPCancellationToken()
        let zedToken = MCPCancellationToken()
        let cursorKey = MCPInflightKey(client: Self.stdioClient("cursor-vscode"), requestId: .number(1))
        let zedKey = MCPInflightKey(client: Self.stdioClient("Zed"), requestId: .number(1))
        #expect(cursorKey != zedKey)

        #expect(await registry.register(key: cursorKey, token: cursorToken, tokenId: nil, method: "tools/call", startedAt: .now))
        #expect(await registry.register(key: zedKey, token: zedToken, tokenId: nil, method: "tools/call", startedAt: .now))
        #expect(await registry.count() == 2)

        #expect(await registry.cancel(key: zedKey, reason: .clientRequested(nil)))
        #expect(await zedToken.isCancelled)
        #expect(!(await cursorToken.isCancelled))

        await registry.remove(key: zedKey, token: zedToken)
        #expect(await registry.contains(key: cursorKey))
    }

    @Test("A token one client holds keys its requests by the token alone")
    func ownTokenKeysByTheTokenAlone() {
        let identity = MCPClientIdentity(
            clientName: "Raycast",
            clientVersion: "1.0",
            tokenId: alice.tokenId,
            tokenName: "Raycast",
            principalFingerprint: alice.tokenFingerprint,
            address: .loopback,
            transport: .http
        )
        #expect(MCPInflightKey(client: identity, requestId: .number(7)) == MCPInflightKey(principal: alice, requestId: .number(7)))
    }

    @Test("A stdio cancellation sent with the renewed bridge credential finds the request the old one started")
    func stdioCancellationCrossesACredentialRotation() async {
        let registry = MCPInflightRegistry()
        let token = MCPCancellationToken()
        let started = MCPInflightKey(client: Self.stdioClient("claude-code", fingerprint: "a"), requestId: .number(5))
        let cancelled = MCPInflightKey(client: Self.stdioClient("claude-code", fingerprint: "b"), requestId: .number(5))

        await registry.register(key: started, token: token, tokenId: nil, method: "tools/call", startedAt: .now)

        #expect(await registry.cancel(key: cancelled, reason: .clientRequested(nil)))
        #expect(await token.isCancelled)
    }

    @Test("Two sessions of one stdio client keep one request id apart, and ending the client ends every session")
    func sessionsOfOneStdioClientAreSeparateEntries() async {
        let registry = MCPInflightRegistry()
        let client = Self.stdioClient("claude-code")
        let tokens = [MCPCancellationToken(), MCPCancellationToken(), MCPCancellationToken()]
        let keys = ["one", "two", "three"].map { MCPInflightKey(client: client, bridgeInstance: $0, requestId: .number(1)) }

        for (key, token) in zip(keys, tokens) {
            #expect(await registry.register(key: key, token: token, tokenId: nil, clientId: client.id, method: "tools/call", startedAt: .now))
        }
        #expect(await registry.count() == 3)

        #expect(await registry.cancel(key: keys[2], reason: .clientRequested(nil)))
        #expect(!(await tokens[0].isCancelled))
        #expect(!(await tokens[1].isCancelled))

        #expect(await registry.cancelAll(matchingClientId: client.id, reason: .clientDisconnected) == 2)
        #expect(await tokens[0].isCancelled)
        #expect(await tokens[1].isCancelled)
    }

    @Test("A stdio cancellation without clientInfo stops the request that had it, by bridge instance and request id")
    func stdioCancellationWithoutClientInfo() async {
        let registry = MCPInflightRegistry()
        let token = MCPCancellationToken()
        let named = Self.stdioClient("claude-code")
        let unnamed = MCPClientIdentity(
            clientName: MCPClientIdentity.unknownClientName,
            clientVersion: nil,
            tokenId: UUID(),
            tokenName: "__stdio_bridge__",
            principalFingerprint: "bridge",
            address: .localSocket,
            transport: .stdioBridge
        )
        let started = MCPInflightKey(client: named, bridgeInstance: "one", requestId: .number(3))
        await registry.register(key: started, token: token, tokenId: nil, clientId: named.id, method: "tools/call", startedAt: .now)

        #expect(!(await registry.cancel(key: MCPInflightKey(client: unnamed, bridgeInstance: "two", requestId: .number(3)), reason: .clientRequested(nil))))
        #expect(await registry.cancel(key: MCPInflightKey(client: unnamed, bridgeInstance: "one", requestId: .number(3)), reason: .clientRequested(nil)))
        #expect(await token.isCancelled)
        #expect(MCPInflightKey(bridgeInstance: "one", requestId: .number(3)) == started)
    }

    @Test("A client on a token of its own cannot pick a bridge instance")
    func ownTokenIgnoresTheBridgeInstance() {
        let identity = MCPClientIdentity(
            clientName: "Raycast",
            clientVersion: "1.0",
            tokenId: alice.tokenId,
            tokenName: "Raycast",
            principalFingerprint: alice.tokenFingerprint,
            address: .loopback,
            transport: .http
        )
        #expect(
            MCPInflightKey(client: identity, bridgeInstance: "forged", requestId: .number(7))
                == MCPInflightKey(principal: alice, requestId: .number(7))
        )
    }

    private static func stdioClient(_ name: String, fingerprint: String = "bridge") -> MCPClientIdentity {
        MCPClientIdentity(
            clientName: name,
            clientInfoName: name,
            clientVersion: "1.0",
            tokenId: UUID(),
            tokenName: "__stdio_bridge__",
            principalFingerprint: fingerprint,
            address: .localSocket,
            transport: .stdioBridge
        )
    }
}
