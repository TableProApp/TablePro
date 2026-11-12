//
//  VaultLeaseCacheTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

private final class Revocations: VaultLeaseRenewing, @unchecked Sendable {
    private let lock = NSLock()
    private var revoked: [String] = []
    private var renewed = 0
    // What Vault answers a renewal: the lease is still there, or it is gone.
    var leaseExists = false

    var leases: [String] { lock.withLock { revoked } }
    var renewals: Int { lock.withLock { renewed } }

    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant {
        let exists = lock.withLock { () -> Bool in
            renewed += 1
            return leaseExists
        }
        guard exists else { throw VaultRequestError(status: 400, messages: ["lease not found"]) }
        return VaultLeaseGrant(leaseDuration: increment, tokenRemaining: nil)
    }

    func revoke(leaseId: String) async {
        lock.withLock { revoked.append(leaseId) }
    }
}

private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] { lock.withLock { recorded } }

    func record(_ name: String) {
        lock.withLock { recorded.append(name) }
    }
}

// Vault's side: each read issues the next lease.
private final class LeaseIssuer: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private let clock: ManualClock
    private let seconds: Int64
    let revocations = Revocations()
    var gate: AsyncGate?

    private let renewable: Bool

    init(clock: ManualClock, seconds: Int64 = 3_600, renewable: Bool = false) {
        self.clock = clock
        self.seconds = seconds
        self.renewable = renewable
    }

    var reads: Int { lock.withLock { issued } }

    func issue() async throws -> VaultLeaseCache.Issued {
        await gate?.wait()
        let number = lock.withLock { () -> Int in
            issued += 1
            return issued
        }
        return VaultLeaseCache.Issued(
            username: "v-token-ro-\(number)",
            password: "s3cret",
            lease: VaultLease(
                leaseId: "database/creds/ro/\(number)",
                grant: VaultLeaseGrant(leaseDuration: .seconds(seconds), tokenRemaining: nil),
                renewable: renewable,
                renewer: revocations,
                clock: clock
            ),
            token: "t0"
        )
    }
}

struct VaultLeaseCacheTests {
    private let owner = UUID()
    private let role = VaultDatabaseRole(mount: "database", role: "ro")

    private func key(owner: UUID? = nil, role: VaultDatabaseRole? = nil, token: String = "t0") throws -> VaultLeaseCache.Key {
        VaultLeaseCache.Key(
            owner: owner ?? self.owner,
            role: role ?? self.role,
            endpoint: try VaultEndpoint.resolve(address: "https://vault.test:8200", environment: [:]),
            token: token
        )
    }

    private func acquire(
        _ cache: VaultLeaseCache,
        _ issuer: LeaseIssuer,
        key: VaultLeaseCache.Key,
        for connection: UUID? = nil
    ) async throws -> VaultLeaseHold {
        try await cache.acquire(key, for: connection) { try await issuer.issue() }
    }

    @Test("One owner and role read one lease")
    func oneReadPerOwnerAndRole() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)

        let first = try await acquire(cache, issuer, key: try key())
        let second = try await acquire(cache, issuer, key: try key())

        #expect(issuer.reads == 1)
        #expect(first.leaseId == second.leaseId)
        #expect(first != second)
    }

    @Test("Another owner, role or token reads a lease of its own")
    func otherKeysReadTheirOwn() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)

        let holds = [
            try await acquire(cache, issuer, key: try key()),
            try await acquire(cache, issuer, key: try key(owner: UUID())),
            try await acquire(cache, issuer, key: try key(role: VaultDatabaseRole(mount: "database", role: "rw"))),
            try await acquire(cache, issuer, key: try key(token: "someone-else")),
        ]

        #expect(issuer.reads == 4)
        #expect(Set(holds.map(\.leaseId)).count == 4)
    }

    @Test("Concurrent sign-ins for one key read one lease, whichever order they reach the cache in")
    func concurrentSignInsReadOneLease() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let gate = AsyncGate()
        issuer.gate = gate
        let key = try key()

        async let first = acquire(cache, issuer, key: key)
        async let second = acquire(cache, issuer, key: key)
        await gate.arrived(1)
        await gate.open()
        let holds = try await [first, second]

        #expect(issuer.reads == 1)
        #expect(holds[0].leaseId == holds[1].leaseId)
    }

    @Test("A failed read leaves nothing behind, so the next sign-in reads again")
    func failedReadIsNotKept() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let key = try key()

        await #expect(throws: VaultError.self) {
            try await cache.acquire(key, for: nil) { throw VaultError.noAddress }
        }
        _ = try await acquire(cache, issuer, key: key)

        #expect(issuer.reads == 1)
    }

    @Test("A sign-in whose caller gave up leaves its lease for the next one, unrevoked")
    func abandonedSignInIsKept() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)

        _ = try await acquire(cache, issuer, key: try key())
        let next = try await acquire(cache, issuer, key: try key())

        #expect(issuer.reads == 1)
        #expect(next.leaseId == "database/creds/ro/1")
        #expect(issuer.revocations.leases.isEmpty)
    }

    @Test("A lease nothing holds is revoked after the idle retention, unless a sign-in takes it first")
    func idleRetention() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)

        try await acquire(cache, issuer, key: try key()).release()
        try await waitUntil { clock.pendingSleeperCount == 2 }
        clock.advance(by: VaultLeaseCache.idleRetention - .seconds(1))
        let again = try await acquire(cache, issuer, key: try key())
        // Only the lease's own schedule is left: the idle timer was cancelled.
        try await waitUntil { clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(1))
        #expect(issuer.revocations.leases.isEmpty)

        again.release()
        try await waitUntil { clock.pendingSleeperCount == 2 }
        clock.advance(by: VaultLeaseCache.idleRetention)

        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
        #expect(issuer.reads == 1)
    }

    @Test("An ended lease is not handed out again, each hold hears its ending, and the last one revokes it")
    func endedLease() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock, seconds: 60)
        let endings = Names()
        let first = try await acquire(cache, issuer, key: try key())
        let second = try await acquire(cache, issuer, key: try key())
        first.start { _ in endings.record("first") }
        second.start { _ in endings.record("second") }

        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(50))

        try await waitUntil { Set(endings.values) == ["first", "second"] }
        let next = try await acquire(cache, issuer, key: try key())
        #expect(next.leaseId == "database/creds/ro/2")
        first.release()
        #expect(issuer.revocations.leases.isEmpty)
        second.release()
        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
    }

    @Test("A refused sign-in on a lease Vault no longer has ends it for every hold and replaces it")
    func refusalOfARevokedLease() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock, renewable: true)
        let endings = Names()
        let session = try await acquire(cache, issuer, key: try key())
        session.start { _ in endings.record("session") }
        let refused = try await acquire(cache, issuer, key: try key())

        refused.signInRefused(credentials: false)

        try await waitUntil { endings.values == ["session"] && refused.hasEnded }
        #expect(try await acquire(cache, issuer, key: try key()).leaseId == "database/creds/ro/2")
        session.release()
        refused.release()
        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
    }

    @Test(
        "A refused sign-in on a lease Vault still has keeps it, unless a server took it and then refused its password",
        arguments: [(false, true), (true, false)]
    )
    func refusalOfALiveLease(accepted: Bool, credentials: Bool) async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock, renewable: true)
        issuer.revocations.leaseExists = true
        let refused = try await acquire(cache, issuer, key: try key())
        if accepted {
            refused.signInAccepted()
        }

        refused.signInRefused(credentials: credentials)
        try await waitUntil { issuer.revocations.renewals == 1 }

        #expect(try await acquire(cache, issuer, key: try key()).leaseId == "database/creds/ro/1")
        #expect(!refused.hasEnded)
        #expect(issuer.revocations.leases.isEmpty)
    }

    @Test("A user a server took and then refused for its password is not handed out again, and sessions keep it")
    func refusalOfAUserDroppedInTheDatabase() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock, renewable: true)
        issuer.revocations.leaseExists = true
        let endings = Names()
        let session = try await acquire(cache, issuer, key: try key())
        session.start { _ in endings.record("session") }
        session.signInAccepted()
        let refused = try await acquire(cache, issuer, key: try key())

        refused.signInRefused(credentials: true)
        refused.release()
        try await waitUntil { issuer.revocations.renewals == 1 }
        session.release()

        // A listed lease would wait out the idle retention instead.
        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
        #expect(endings.values.isEmpty)
        #expect(try await acquire(cache, issuer, key: try key()).leaseId == "database/creds/ro/2")
    }

    @Test("Ending a connection revokes a lease only it used, including after a late release")
    func endUseRevokesTheConnectionsLease() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let connection = UUID()
        let session = try await acquire(cache, issuer, key: try key(), for: connection)
        let pooledRead = try await acquire(cache, issuer, key: try key(), for: connection)
        session.release()

        cache.endUse(connection: connection, live: [])
        // Still there while the read holds it.
        #expect(pooledRead.redialDelay(afterFailures: 1) != nil)
        pooledRead.release()

        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
        #expect(try await acquire(cache, issuer, key: try key()).leaseId == "database/creds/ro/2")
    }

    @Test("A read left over from a connection ended earlier does not keep the lease past the last disconnect")
    func leftoverReadDoesNotKeepTheLease() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let first = UUID()
        let second = UUID()
        let firstsRead = try await acquire(cache, issuer, key: try key(), for: first)
        let seconds = try await acquire(cache, issuer, key: try key(), for: second)

        cache.endUse(connection: first, live: [second])
        seconds.release()
        cache.endUse(connection: second, live: [])
        firstsRead.release()

        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
    }

    @Test("Ending a connection leaves a lease another live connection is reconnecting with")
    func endUseKeepsALeaseBetweenDrivers() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let ended = UUID()
        let reconnecting = UUID()
        try await acquire(cache, issuer, key: try key(), for: ended).release()
        try await acquire(cache, issuer, key: try key(), for: reconnecting).release()

        cache.endUse(connection: ended, live: [reconnecting])

        #expect(try await acquire(cache, issuer, key: try key(), for: reconnecting).leaseId == "database/creds/ro/1")
        #expect(issuer.reads == 1)
    }

    @Test("Ending a hold whose password left the process revokes the lease at once")
    func endRevokesAtOnce() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)

        try await acquire(cache, issuer, key: try key(owner: UUID())).end()

        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
    }

    @Test("Ending one connection leaves a lease another connection on the profile still holds")
    func endUseLeavesSharedLease() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let ended = UUID()
        let other = UUID()
        let mine = try await acquire(cache, issuer, key: try key(), for: ended)
        let theirs = try await acquire(cache, issuer, key: try key(), for: other)
        mine.release()

        cache.endUse(connection: ended, live: [other])

        #expect(try await acquire(cache, issuer, key: try key()).leaseId == "database/creds/ro/1")
        #expect(issuer.revocations.leases.isEmpty)
        theirs.release()
    }

    @Test("Quit revokes every lease, held or not, and waits for Vault to answer")
    func revokeAll() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let held = try await acquire(cache, issuer, key: try key())
        try await acquire(cache, issuer, key: try key(owner: UUID())).release()

        await cache.revokeAll(within: .seconds(3))

        #expect(Set(issuer.revocations.leases) == ["database/creds/ro/1", "database/creds/ro/2"])
        held.release()
    }

    @Test("A lease read after the quit revoke is revoked at once and the sign-in is cancelled")
    func readFinishingAfterQuit() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let issuer = LeaseIssuer(clock: clock)
        let gate = AsyncGate()
        issuer.gate = gate

        let signIn = Task { try await acquire(cache, issuer, key: try key()) }
        await gate.arrived(1)
        await cache.revokeAll(within: .seconds(3))
        await gate.open()

        await #expect(throws: CancellationError.self) { try await signIn.value }
        try await waitUntil { issuer.revocations.leases == ["database/creds/ro/1"] }
    }

    @Test("A refused new user is dialed again after 2, 4 and 8 seconds, then only until the window closes")
    func redialDelays() async throws {
        let clock = ManualClock()
        let cache = VaultLeaseCache(clock: clock)
        let hold = try await acquire(cache, LeaseIssuer(clock: clock), key: try key())

        #expect(hold.redialDelay(afterFailures: 1) == .seconds(2))
        #expect(hold.redialDelay(afterFailures: 2) == .seconds(4))
        #expect(hold.redialDelay(afterFailures: 3) == .seconds(8))
        clock.advance(by: .seconds(14))
        #expect(hold.redialDelay(afterFailures: 4) == .seconds(16))
        clock.advance(by: .seconds(6))
        #expect(hold.redialDelay(afterFailures: 4) == .seconds(10))
        clock.advance(by: .seconds(10))
        #expect(hold.redialDelay(afterFailures: 5) == nil)
    }
}
