//
//  VaultLeaseOwnershipTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class SilentPluginDriver: PluginDriverStub, @unchecked Sendable {}

private struct ServerRefusal: PluginDriverError {
    let pluginErrorMessage: String
    let pluginErrorCode: Int?
    let pluginSqlState: String?

    static let unknownUser = ServerRefusal(
        pluginErrorMessage: "Access denied for user 'v-token-ro-1'",
        pluginErrorCode: 1_045,
        pluginSqlState: "28000"
    )
}

// Refuses the first `refusals` dials the way a database that has not loaded a new user does.
private final class SlowToAcceptDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var dials = 0
    private let refusals: Int
    private let refusal: Error

    init(refusals: Int, refusal: Error = ServerRefusal.unknownUser) {
        self.refusals = refusals
        self.refusal = refusal
    }

    var attempts: Int { lock.withLock { dials } }

    func connect() async throws {
        let attempt = lock.withLock { () -> Int in
            dials += 1
            return dials
        }
        if attempt <= refusals { throw refusal }
    }
}

private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var value: Int { lock.withLock { reads } }

    func count() {
        lock.withLock { reads += 1 }
    }
}

private final class RevokeRecorder: VaultLeaseRenewing, @unchecked Sendable {
    private let lock = NSLock()
    private var revoked: [String] = []
    // What Vault answers a renewal: the lease is still there, or it is gone.
    var leaseExists = false

    var revokedLeases: [String] { lock.withLock { revoked } }

    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant {
        guard lock.withLock({ leaseExists }) else { throw VaultRequestError(status: 400, messages: ["lease not found"]) }
        return VaultLeaseGrant(leaseDuration: increment, tokenRemaining: nil)
    }

    func revoke(leaseId: String) async {
        lock.withLock { revoked.append(leaseId) }
    }
}

@MainActor
struct VaultLeaseOwnershipTests {
    private let owner = UUID()
    private let role = VaultDatabaseRole(mount: "database", role: "ro")

    private func hold(
        _ cache: VaultLeaseCache,
        recorder: RevokeRecorder,
        clock: ManualClock,
        seconds: Int64 = 3_600,
        renewable: Bool = false,
        for connection: UUID? = nil,
        reads: Reads = Reads()
    ) async throws -> VaultLeaseHold {
        let endpoint = try VaultEndpoint.resolve(address: "https://vault.test:8200", environment: [:])
        let key = VaultLeaseCache.Key(owner: owner, role: role, endpoint: endpoint, token: "t0")
        return try await cache.acquire(key, for: connection) {
            reads.count()
            return VaultLeaseCache.Issued(
                username: "v-token-ro-1",
                password: "s3cret",
                lease: VaultLease(
                    leaseId: "database/creds/ro/1",
                    grant: VaultLeaseGrant(leaseDuration: .seconds(seconds), tokenRemaining: nil),
                    renewable: renewable,
                    renewer: recorder,
                    clock: clock
                ),
                token: "t0"
            )
        }
    }

    @Test("A driver's disconnect hands the lease back, and the cache revokes it once it sits unused")
    func disconnectHandsTheLeaseBack() async throws {
        let recorder = RevokeRecorder()
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: SilentPluginDriver(),
            credentialLease: try await hold(cache, recorder: recorder, clock: clock)
        )

        adapter.disconnect()
        adapter.disconnect()

        // The lease's own end and the idle retention.
        try await waitUntil { clock.pendingSleeperCount == 2 }
        #expect(recorder.revokedLeases.isEmpty)
        clock.advance(by: VaultLeaseCache.idleRetention)
        try await waitUntil { recorder.revokedLeases == ["database/creds/ro/1"] }
    }

    @Test("A driver whose lease ended reports its connection lost, so pooled work opens a fresh one")
    func endedLeaseIsLostConnection() async throws {
        let recorder = RevokeRecorder()
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: SilentPluginDriver(),
            credentialLease: try await hold(cache, recorder: recorder, clock: clock, seconds: 60)
        )
        #expect(!adapter.hasLostConnection)

        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(50))

        try await waitUntil { adapter.hasLostConnection }
        adapter.disconnect()
    }

    @Test("A refused sign-in on a new lease dials again until the database accepts the user")
    func youngLeaseRedials() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let driver = SlowToAcceptDriver(refusals: 2)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: driver,
            credentialLease: try await hold(cache, recorder: RevokeRecorder(), clock: clock)
        )

        let connect = Task { try await adapter.connect() }
        try await waitUntil { driver.attempts == 1 && clock.pendingSleeperCount == 2 }
        clock.advance(by: .seconds(2))
        try await waitUntil { driver.attempts == 2 && clock.pendingSleeperCount == 2 }
        clock.advance(by: .seconds(4))
        try await connect.value

        #expect(driver.attempts == 3)
        #expect(adapter.status == .connected)
        adapter.disconnect()
    }

    @Test("A user still refused when the window closes fails with the reason and is kept for the next attempt")
    func refusedThroughTheWindow() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let reads = Reads()
        let recorder = RevokeRecorder()
        let driver = SlowToAcceptDriver(refusals: 10)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: driver,
            credentialLease: try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        )

        let connect = Task { try await adapter.connect() }
        for (attempt, wait) in [(1, 2), (2, 4), (3, 8), (4, 16)] {
            try await waitUntil { driver.attempts == attempt && clock.pendingSleeperCount == 2 }
            clock.advance(by: .seconds(wait))
        }

        let error = await #expect(throws: VaultUserNotLoaded.self) { try await connect.value }
        #expect(driver.attempts == 5)
        #expect(error?.pluginErrorCode == 1_045)
        #expect(error?.recoverySuggestion != nil)
        adapter.disconnect()
        _ = try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        #expect(reads.value == 1)
    }

    @Test("A refusal of a dial that started past the window fails at once and keeps a user Vault still has")
    func oldLeaseFailsAtOnce() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let reads = Reads()
        let recorder = RevokeRecorder()
        let driver = SlowToAcceptDriver(refusals: 1)
        let lease = try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        clock.advance(by: VaultLeaseCache.acceptanceWindow)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: driver,
            credentialLease: lease
        )

        await #expect(throws: ServerRefusal.self) { try await adapter.connect() }
        #expect(driver.attempts == 1)
        adapter.disconnect()
        _ = try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        #expect(reads.value == 1)
    }

    @Test("A refused sign-in on any engine asks Vault, and a user Vault revoked is replaced, without dialing again")
    func otherEngineRefusalReplacesTheUser() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let reads = Reads()
        let recorder = RevokeRecorder()
        let refusal = ServerRefusal(
            pluginErrorMessage: "password authentication failed for user \"v-token-ro-1\"",
            pluginErrorCode: nil,
            pluginSqlState: nil
        )
        let driver = SlowToAcceptDriver(refusals: 1, refusal: refusal)
        let lease = try await hold(cache, recorder: recorder, clock: clock, renewable: true, reads: reads)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: driver,
            credentialLease: lease
        )

        await #expect(throws: ServerRefusal.self) { try await adapter.connect() }
        #expect(driver.attempts == 1)
        try await waitUntil { lease.hasEnded }
        adapter.disconnect()
        _ = try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        #expect(reads.value == 2)
    }

    @Test("A MySQL user a connection signed in with and another is refused for is not handed out again")
    func acceptedUserRefusedLater() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let recorder = RevokeRecorder()
        recorder.leaseExists = true
        let first = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: SlowToAcceptDriver(refusals: 0),
            credentialLease: try await hold(cache, recorder: recorder, clock: clock, renewable: true)
        )
        try await first.connect()
        clock.advance(by: VaultLeaseCache.acceptanceWindow)
        let second = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: SlowToAcceptDriver(refusals: 1),
            credentialLease: try await hold(cache, recorder: recorder, clock: clock, renewable: true)
        )

        await #expect(throws: ServerRefusal.self) { try await second.connect() }
        second.disconnect()
        first.disconnect()

        // A lease still handed out would wait out the idle retention instead.
        try await waitUntil { recorder.revokedLeases == ["database/creds/ro/1"] }
    }

    @Test("A refused database is not dialed again and keeps the user the profile signs in with")
    func otherErrorFailsAtOnce() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let reads = Reads()
        let recorder = RevokeRecorder()
        let wrongDatabase = ServerRefusal(
            pluginErrorMessage: "Access denied for user 'v-token-ro-1' to database 'orders'",
            pluginErrorCode: 1_044,
            pluginSqlState: "42000"
        )
        let driver = SlowToAcceptDriver(refusals: 1, refusal: wrongDatabase)
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: driver,
            credentialLease: try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        )

        await #expect(throws: ServerRefusal.self) { try await adapter.connect() }
        #expect(driver.attempts == 1)
        adapter.disconnect()
        _ = try await hold(cache, recorder: recorder, clock: clock, reads: reads)
        #expect(reads.value == 1)
    }

    @Test("A connect cancelled while it waits for the database dials no more")
    func cancelledWaitStopsDialing() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let driver = SlowToAcceptDriver(refusals: 5)
        let ended = UUID()
        let lease = try await hold(cache, recorder: RevokeRecorder(), clock: clock, for: ended)
        // Unlisted, so letting go of it revokes it and leaves no idle timer among the sleepers counted below.
        cache.endUse(connection: ended, live: [])
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: driver,
            credentialLease: lease
        )

        let connect = Task { try await adapter.connect() }
        try await waitUntil { driver.attempts == 1 && clock.pendingSleeperCount == 2 }
        connect.cancel()
        await #expect(throws: CancellationError.self) { try await connect.value }
        // Neither the redial's wait nor the lease's schedule is left.
        try await waitUntil { clock.pendingSleeperCount == 0 }
        clock.advance(by: VaultLeaseCache.acceptanceWindow)

        #expect(driver.attempts == 1)
    }
}
