import Foundation
@testable import TablePro
import Testing

@Suite("MCP legacy session store")
struct MCPLegacySessionStoreTests {
    @Test("A minted session id is printable, unique and well formed")
    func mintedSessionIdsAreWellFormed() {
        let first = MCPLegacySessionId.generate()
        let second = MCPLegacySessionId.generate()

        #expect(first != second)
        #expect(first.isWellFormed)
        #expect(first.rawValue.count == 64)
        #expect(first.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(first.redacted.count == 8)
        #expect(first.rawValue.hasPrefix(first.redacted))
    }

    @Test("An empty, oversized or non-printable session id is not well formed")
    func malformedSessionIdsAreRejected() {
        #expect(!MCPLegacySessionId("").isWellFormed)
        #expect(!MCPLegacySessionId(String(repeating: "a", count: 513)).isWellFormed)
        #expect(!MCPLegacySessionId("has space").isWellFormed)
        #expect(!MCPLegacySessionId("tab\tseparated").isWellFormed)
        #expect(MCPLegacySessionId(String(repeating: "a", count: 512)).isWellFormed)
    }

    @Test("Establishing a session records the handshake it was created with")
    func establishRecordsTheHandshake() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")

        let id = await store.establish(
            owner: owner,
            protocolVersion: .v20250618,
            clientInfo: MCPImplementation(name: "acme-cli", version: "9.9.9"),
            clientCapabilities: MCPClientCapabilities(json: .object(["roots": .object([:])]))
        )

        let lookup = await store.lookup(id: id, presentedBy: LegacyStoreFixtures.principal(for: owner))
        guard case .found(let session) = lookup else {
            Issue.record("Expected the session to be found")
            return
        }
        #expect(session.protocolVersion == .v20250618)
        #expect(session.clientInfo?.name == "acme-cli")
        #expect(session.clientCapabilities.supportsRoots)
        #expect(session.owner == owner)
    }

    @Test("The same owner repeating the same handshake reuses its session")
    func theSameHandshakeReusesTheSession() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")

        let first = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "acme-cli")
        let second = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "acme-cli")

        #expect(first == second)
        let count = await store.count()
        #expect(count == 1)
    }

    @Test("A reused session adopts the capabilities the new handshake declared")
    func reusedSessionAdoptsTheNewCapabilities() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        _ = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "acme-cli")

        let id = await store.establish(
            owner: owner,
            protocolVersion: .v20251125,
            clientInfo: MCPImplementation(name: "acme-cli", version: "9.9.9"),
            clientCapabilities: MCPClientCapabilities(json: .object(["elicitation": .object([:])]))
        )

        let lookup = await store.lookup(id: id, presentedBy: LegacyStoreFixtures.principal(for: owner))
        guard case .found(let session) = lookup else {
            Issue.record("Expected the session to be found")
            return
        }
        #expect(session.clientCapabilities.supportsElicitation)
        let count = await store.count()
        #expect(count == 1)
    }

    @Test("A different client name is a different handshake and gets its own session")
    func differentHandshakeGetsItsOwnSession() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")

        let first = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "acme-cli")
        let second = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "other-cli")

        #expect(first != second)
        let count = await store.count()
        #expect(count == 2)
    }

    @Test("A different owner never reuses another owner's session")
    func differentOwnerGetsItsOwnSession() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let alice = LegacyStoreFixtures.owner(fingerprint: "alice", tokenId: UUID())
        let bob = LegacyStoreFixtures.owner(fingerprint: "bob", tokenId: UUID())

        let first = await LegacyStoreFixtures.establish(in: store, owner: alice, clientName: "acme-cli")
        let second = await LegacyStoreFixtures.establish(in: store, owner: bob, clientName: "acme-cli")

        #expect(first != second)
        let count = await store.count()
        #expect(count == 2)
    }

    @Test("A lookup touches the session so it counts as recently used")
    func lookupTouchesTheSession() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let id = await LegacyStoreFixtures.establish(in: store, owner: owner)
        let created = await store.snapshots().first?.lastActivityAt

        await clock.advance(by: .seconds(120))
        _ = await store.lookup(id: id, presentedBy: LegacyStoreFixtures.principal(for: owner))

        let touched = await store.snapshots().first?.lastActivityAt
        #expect(created == LegacyStoreFixtures.start)
        #expect(touched == LegacyStoreFixtures.start.addingTimeInterval(120))
    }

    @Test("A session presented by a different principal reports a principal mismatch")
    func differentPrincipalIsAMismatch() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let alice = LegacyStoreFixtures.owner(fingerprint: "alice", tokenId: UUID())
        let mallory = LegacyStoreFixtures.owner(fingerprint: "mallory", tokenId: UUID())
        let id = await LegacyStoreFixtures.establish(in: store, owner: alice)

        let lookup = await store.lookup(id: id, presentedBy: LegacyStoreFixtures.principal(for: mallory))

        guard case .principalMismatch = lookup else {
            Issue.record("Expected a principal mismatch, got \(lookup)")
            return
        }
    }

    @Test("A principal mismatch does not touch the session it failed to reach")
    func mismatchDoesNotTouchTheSession() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(clock: clock)
        let alice = LegacyStoreFixtures.owner(fingerprint: "alice", tokenId: UUID())
        let mallory = LegacyStoreFixtures.owner(fingerprint: "mallory", tokenId: UUID())
        let id = await LegacyStoreFixtures.establish(in: store, owner: alice)

        await clock.advance(by: .seconds(300))
        _ = await store.lookup(id: id, presentedBy: LegacyStoreFixtures.principal(for: mallory))

        let lastActivity = await store.snapshots().first?.lastActivityAt
        #expect(lastActivity == LegacyStoreFixtures.start)
    }

    @Test("An unknown or malformed session id is unknown, never someone else's session")
    func unknownIdsAreUnknown() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        _ = await LegacyStoreFixtures.establish(in: store, owner: owner)

        for candidate in [MCPLegacySessionId.generate(), MCPLegacySessionId(""), MCPLegacySessionId("has space")] {
            let presenter = LegacyStoreFixtures.principal(for: owner)
            let lookup = await store.lookup(id: candidate, presentedBy: presenter)
            guard case .unknown = lookup else {
                Issue.record("Expected \(candidate.rawValue) to be unknown, got \(lookup)")
                return
            }
        }
    }

    @Test("Reaching the capacity limit evicts the least recently used session instead of refusing")
    func capacityEvictsTheLeastRecentlyUsedSession() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(maxSessions: 3), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")

        let first = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "first")
        await clock.advance(by: .seconds(10))
        let second = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "second")
        await clock.advance(by: .seconds(10))
        let third = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "third")
        await clock.advance(by: .seconds(10))
        _ = await store.lookup(id: first, presentedBy: LegacyStoreFixtures.principal(for: owner))
        await clock.advance(by: .seconds(10))
        let fourth = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "fourth")

        let count = await store.count()
        let keptFirst = await LegacyStoreFixtures.isKnown(first, in: store, owner: owner)
        let keptSecond = await LegacyStoreFixtures.isKnown(second, in: store, owner: owner)
        let keptThird = await LegacyStoreFixtures.isKnown(third, in: store, owner: owner)
        let keptFourth = await LegacyStoreFixtures.isKnown(fourth, in: store, owner: owner)
        #expect(count == 3)
        #expect(!keptSecond)
        #expect(keptFirst)
        #expect(keptThird)
        #expect(keptFourth)
    }

    @Test("A client that keeps handshaking is always served, never refused for a quarter of an hour")
    func busyClientIsNeverRefused() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(maxSessions: 4), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")

        var served: [MCPLegacySessionId] = []
        for index in 0 ..< 40 {
            let id = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "client-\(index)")
            served.append(id)
            await clock.advance(by: .seconds(1))
        }

        let count = await store.count()
        let keptNewest = await LegacyStoreFixtures.isKnown(served[39], in: store, owner: owner)
        #expect(served.count == 40)
        #expect(Set(served).count == 40)
        #expect(count == 4)
        #expect(keptNewest)
    }

    @Test("Eviction spares a session that still has work in flight")
    func evictionSparesABusySession() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(maxSessions: 2), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let busy = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "busy")
        let token = MCPCancellationToken()
        await store.trackInFlight(id: busy, requestId: .number(1), token: token)

        await clock.advance(by: .seconds(10))
        let idle = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "idle")
        await clock.advance(by: .seconds(10))
        let newcomer = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "newcomer")

        let keptBusy = await LegacyStoreFixtures.isKnown(busy, in: store, owner: owner)
        let keptIdle = await LegacyStoreFixtures.isKnown(idle, in: store, owner: owner)
        let keptNewcomer = await LegacyStoreFixtures.isKnown(newcomer, in: store, owner: owner)
        let cancelled = await token.isCancelled
        #expect(keptBusy)
        #expect(!keptIdle)
        #expect(keptNewcomer)
        #expect(!cancelled)
    }

    @Test("An evicted session has its in-flight work cancelled as a shutdown")
    func evictionCancelsTheEvictedSessionsWork() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(maxSessions: 1), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let doomed = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "doomed")
        let token = MCPCancellationToken()
        await store.trackInFlight(id: doomed, requestId: .number(1), token: token)

        await clock.advance(by: .seconds(10))
        _ = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "newcomer")

        let cancelled = await token.isCancelled
        let reason = await token.reason
        #expect(cancelled)
        #expect(reason == .serverShuttingDown)
        let count = await store.count()
        #expect(count == 1)
    }

    @Test("Terminating a session cancels every request it still has in flight")
    func terminateCancelsInFlightWork() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let id = await LegacyStoreFixtures.establish(in: store, owner: owner)
        let first = MCPCancellationToken()
        let second = MCPCancellationToken()
        await store.trackInFlight(id: id, requestId: .number(1), token: first)
        await store.trackInFlight(id: id, requestId: .number(2), token: second)

        await store.terminate(id: id, reason: .clientRequested)

        let firstCancelled = await first.isCancelled
        let secondCancelled = await second.isCancelled
        #expect(firstCancelled)
        #expect(secondCancelled)
        let count = await store.count()
        #expect(count == 0)
    }

    @Test("Terminating an unknown session is a no-op")
    func terminatingAnUnknownSessionIsANoOp() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        _ = await LegacyStoreFixtures.establish(in: store, owner: owner)

        await store.terminate(id: MCPLegacySessionId.generate(), reason: .clientRequested)

        let count = await store.count()
        #expect(count == 1)
    }

    @Test("Every termination reason maps to the cancellation reason it means")
    func terminationReasonsMapToCancellationReasons() {
        #expect(MCPLegacySessionTerminationReason.clientRequested.cancellationReason == .clientRequested(nil))
        #expect(MCPLegacySessionTerminationReason.idleTimeout.cancellationReason == .deadlineExceeded)
        #expect(MCPLegacySessionTerminationReason.capacityEvicted.cancellationReason == .serverShuttingDown)
        #expect(MCPLegacySessionTerminationReason.serverShutdown.cancellationReason == .serverShuttingDown)
        #expect(MCPLegacySessionTerminationReason.tokenRevoked.cancellationReason == .credentialRevoked)
    }

    @Test("Revoking a token terminates only the sessions that token owns")
    func revokingATokenTerminatesOnlyItsOwnSessions() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let revokedTokenId = UUID()
        let revoked = LegacyStoreFixtures.owner(fingerprint: "alice", tokenId: revokedTokenId)
        let survivor = LegacyStoreFixtures.owner(fingerprint: "bob", tokenId: UUID())
        let doomed = await LegacyStoreFixtures.establish(in: store, owner: revoked)
        let kept = await LegacyStoreFixtures.establish(in: store, owner: survivor)
        let token = MCPCancellationToken()
        await store.trackInFlight(id: doomed, requestId: .number(1), token: token)

        let terminated = await store.terminateAll(ownedByTokenId: revokedTokenId, reason: .tokenRevoked)

        let cancelled = await token.isCancelled
        let reason = await token.reason
        let keptSurvivor = await LegacyStoreFixtures.isKnown(kept, in: store, owner: survivor)
        #expect(terminated == [doomed])
        #expect(cancelled)
        #expect(reason == .credentialRevoked)
        #expect(keptSurvivor)
    }

    @Test("The idle sweep terminates a session that has been quiet past the idle timeout")
    func theIdleSweepTerminatesQuietSessions() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(idleTimeout: .seconds(900)), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        _ = await LegacyStoreFixtures.establish(in: store, owner: owner)

        await clock.advance(by: .seconds(901))
        await store.runIdleSweep()

        let count = await store.count()
        #expect(count == 0)
    }

    @Test("The idle sweep leaves a session that was active inside the window")
    func theIdleSweepLeavesActiveSessions() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(idleTimeout: .seconds(900)), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let id = await LegacyStoreFixtures.establish(in: store, owner: owner)

        await clock.advance(by: .seconds(600))
        _ = await store.lookup(id: id, presentedBy: LegacyStoreFixtures.principal(for: owner))
        await clock.advance(by: .seconds(600))
        await store.runIdleSweep()

        let count = await store.count()
        #expect(count == 1)
    }

    @Test("The idle sweep never terminates a session with work in flight")
    func theIdleSweepSparesBusySessions() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(idleTimeout: .seconds(900)), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let id = await LegacyStoreFixtures.establish(in: store, owner: owner)
        await store.trackInFlight(id: id, requestId: .number(1), token: MCPCancellationToken())

        await clock.advance(by: .seconds(5_000))
        await store.runIdleSweep()

        let count = await store.count()
        #expect(count == 1)
    }

    @Test("A request released before the idle sweep is never cancelled by it")
    func releasedRequestIsNotCancelledByTheIdleSweep() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(policy: LegacyStoreFixtures.policy(idleTimeout: .seconds(900)), clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let id = await LegacyStoreFixtures.establish(in: store, owner: owner)
        let token = MCPCancellationToken()
        await store.trackInFlight(id: id, requestId: .number(1), token: token)
        await store.releaseInFlight(id: id, requestId: .number(1))

        await clock.advance(by: .seconds(901))
        await store.runIdleSweep()

        let reason = await token.reason
        #expect(reason == nil)
        let count = await store.count()
        #expect(count == 0)
    }

    @Test("Releasing an in-flight request clears it from the session")
    func releaseClearsTheInFlightRequest() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let id = await LegacyStoreFixtures.establish(in: store, owner: owner)
        await store.trackInFlight(id: id, requestId: .number(1), token: MCPCancellationToken())

        await store.releaseInFlight(id: id, requestId: .number(1))

        let snapshot = await store.snapshots().first
        #expect(snapshot?.inFlightRequestCount == 0)
    }

    @Test("Shutting down terminates every session and cancels their work")
    func shutdownTerminatesEverything() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let first = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "first")
        let second = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "second")
        let firstToken = MCPCancellationToken()
        let secondToken = MCPCancellationToken()
        await store.trackInFlight(id: first, requestId: .number(1), token: firstToken)
        await store.trackInFlight(id: second, requestId: .number(2), token: secondToken)

        await store.shutdown()

        let count = await store.count()
        #expect(count == 0)
        let firstReason = await firstToken.reason
        let secondReason = await secondToken.reason
        #expect(firstReason == .serverShuttingDown)
        #expect(secondReason == .serverShuttingDown)
    }

    @Test("Snapshots are ordered oldest first and carry the in-flight count")
    func snapshotsAreOrderedByCreation() async {
        let clock = LegacyEraTestClock()
        let store = MCPLegacySessionStore(clock: clock)
        let owner = LegacyStoreFixtures.owner(fingerprint: "alice")
        let first = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "first")
        await clock.advance(by: .seconds(30))
        let second = await LegacyStoreFixtures.establish(in: store, owner: owner, clientName: "second")
        await store.trackInFlight(id: second, requestId: .number(1), token: MCPCancellationToken())

        let snapshots = await store.snapshots()

        #expect(snapshots.map(\.id) == [first, second])
        #expect(snapshots.first?.inFlightRequestCount == 0)
        #expect(snapshots.last?.inFlightRequestCount == 1)
        #expect(snapshots.first?.createdAt == LegacyStoreFixtures.start)
        #expect(snapshots.last?.createdAt == LegacyStoreFixtures.start.addingTimeInterval(30))
    }

    @Test("A capacity below one is raised to one rather than locking every client out")
    func policyNeverAllowsAZeroCapacity() {
        let zero = LegacyStoreFixtures.policy(maxSessions: 0)
        let negative = LegacyStoreFixtures.policy(maxSessions: -5)

        #expect(zero.maxSessions == 1)
        #expect(negative.maxSessions == 1)
    }

    @Test("The standard policy keeps sessions for fifteen minutes and sweeps every minute")
    func theStandardPolicyIsDocumented() {
        #expect(MCPLegacySessionPolicy.standard.idleTimeoutSeconds == 900)
        #expect(MCPLegacySessionPolicy.standard.sweepIntervalSeconds == 60)
        #expect(MCPLegacySessionPolicy.standard.maxSessions == 16)
    }

    @Test("Stopping an idle sweep that never started is safe")
    func stoppingAnUnstartedSweepIsSafe() async {
        let store = MCPLegacySessionStore(clock: LegacyEraTestClock())

        await store.stopIdleSweep()
        await store.stopIdleSweep()

        let count = await store.count()
        #expect(count == 0)
    }
}

enum LegacyStoreFixtures {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    static func owner(fingerprint: String, tokenId: UUID? = nil) -> MCPLegacySessionOwner {
        MCPLegacySessionOwner(tokenId: tokenId, tokenFingerprint: fingerprint)
    }

    static func policy(
        idleTimeout: Duration = .seconds(900),
        maxSessions: Int = 16,
        sweepInterval: Duration = .seconds(60)
    ) -> MCPLegacySessionPolicy {
        MCPLegacySessionPolicy(idleTimeout: idleTimeout, maxSessions: maxSessions, sweepInterval: sweepInterval)
    }

    static func establish(
        in store: MCPLegacySessionStore,
        owner: MCPLegacySessionOwner,
        protocolVersion: MCPProtocolVersion = .v20251125,
        clientName: String = "acme-cli"
    ) async -> MCPLegacySessionId {
        await store.establish(
            owner: owner,
            protocolVersion: protocolVersion,
            clientInfo: MCPImplementation(name: clientName, version: "1.0.0"),
            clientCapabilities: .none
        )
    }

    static func isKnown(
        _ id: MCPLegacySessionId,
        in store: MCPLegacySessionStore,
        owner: MCPLegacySessionOwner
    ) async -> Bool {
        if case .found = await store.lookup(id: id, presentedBy: principal(for: owner)) {
            return true
        }
        return false
    }

    static func principal(for owner: MCPLegacySessionOwner) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: owner.tokenFingerprint,
            tokenId: owner.tokenId,
            scopes: MCPScope.readWriteSet,
            metadata: MCPPrincipalMetadata(label: owner.tokenFingerprint, issuedAt: start, expiresAt: nil)
        )
    }
}
