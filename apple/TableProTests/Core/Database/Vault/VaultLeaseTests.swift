//
//  VaultLeaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

private final class RecordingRenewer: VaultLeaseRenewing, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [Result<VaultLeaseGrant, Error>]
    private var renewals: [Duration] = []
    private var revoked: [String] = []

    init(_ grants: [Result<VaultLeaseGrant, Error>]) {
        self.grants = grants
    }

    var renewalCount: Int { lock.withLock { renewals.count } }
    var increments: [Duration] { lock.withLock { renewals } }
    var revokedLeases: [String] { lock.withLock { revoked } }

    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant {
        let next = lock.withLock { () -> Result<VaultLeaseGrant, Error> in
            renewals.append(increment)
            return grants.count > 1 ? grants.removeFirst() : grants[0]
        }
        return try next.get()
    }

    func revoke(leaseId: String) async {
        lock.withLock { revoked.append(leaseId) }
    }
}

// Stands in for a Vault that takes 15 seconds to fail.
private final class SlowFailingRenewer: VaultLeaseRenewing, @unchecked Sendable {
    private let clock: ManualClock
    private let lock = NSLock()
    private var budgets: [Duration] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    var timeouts: [Duration] { lock.withLock { budgets } }

    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant {
        lock.withLock { budgets.append(timeout) }
        clock.advance(by: .seconds(15))
        throw VaultError.unreachable("https://vault.test", "timed out")
    }

    func revoke(leaseId: String) async {}
}

private final class EndingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    var endings: [Duration] { lock.withLock { values } }

    func record(_ remaining: Duration) {
        lock.withLock { values.append(remaining) }
    }
}

struct VaultLeaseTests {
    private func grant(_ seconds: Int64, token: Int64? = nil) -> VaultLeaseGrant {
        VaultLeaseGrant(leaseDuration: .seconds(seconds), tokenRemaining: token.map { .seconds($0) })
    }

    @Test("A renewable lease renews at two thirds of its grant")
    func renewsAtTwoThirds() {
        let schedule = VaultLeaseSchedule(initialDuration: .seconds(3_600), renewable: true)
        #expect(schedule.lead == .seconds(120))
        #expect(schedule.next(after: grant(3_600)) == .renew(after: .seconds(2_400)))
    }

    @Test("A grant cut short by the max TTL ends the lease a lead before it runs out")
    func cappedGrantEnds() {
        let schedule = VaultLeaseSchedule(initialDuration: .seconds(3_600), renewable: true)
        #expect(schedule.next(after: grant(150)) == .end(after: .seconds(30)))
        #expect(schedule.next(after: grant(60)) == .end(after: .zero))
    }

    @Test("A short lease still renews before its lead")
    func shortLeaseRenews() {
        let schedule = VaultLeaseSchedule(initialDuration: .seconds(60), renewable: true)
        #expect(schedule.lead == .seconds(10))
        #expect(schedule.next(after: grant(60)) == .renew(after: .seconds(40)))
    }

    @Test("A lease that cannot be renewed ends a lead before its TTL")
    func nonRenewableEnds() {
        let schedule = VaultLeaseSchedule(initialDuration: .seconds(3_600), renewable: false)
        #expect(schedule.next(after: grant(3_600)) == .end(after: .seconds(3_480)))
    }

    @Test("A minted token that expires first sets the horizon")
    func tokenBoundsHorizon() {
        let schedule = VaultLeaseSchedule(initialDuration: .seconds(3_600), renewable: true)
        #expect(schedule.next(after: grant(3_600, token: 1_200)) == .renew(after: .seconds(800)))
        #expect(schedule.next(after: grant(3_600, token: 200)) == .end(after: .seconds(80)))
    }

    @Test("A minted token shorter than the lease sets the lead, so the lease renews instead of ending at once")
    func tokenSetsTheLead() {
        let schedule = VaultLeaseSchedule(initialDuration: .seconds(3_600), renewable: true, leadBasis: .seconds(120))
        #expect(schedule.lead == .seconds(12))
        #expect(schedule.next(after: grant(3_600, token: 120)) == .renew(after: .seconds(80)))
    }

    @Test("The lease renews with its original increment until a short grant ends it")
    func renewsThenEnds() async throws {
        let clock = ManualClock()
        let renewer = RecordingRenewer([.success(grant(60)), .success(grant(30))])
        let endings = EndingRecorder()
        let lease = VaultLease(leaseId: "l1", grant: grant(60), renewable: true, renewer: renewer, clock: clock)

        lease.start { endings.record($0) }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(40))
        try await waitUntil { renewer.renewalCount == 1 }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(40))
        try await waitUntil { renewer.renewalCount == 2 }
        #expect(!lease.hasEnded)
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(20))
        try await waitUntil { lease.hasEnded }

        #expect(renewer.increments == [.seconds(60), .seconds(60)])
        #expect(endings.endings == [.seconds(10)])
        #expect(renewer.revokedLeases.isEmpty)
        lease.release()
    }

    @Test("A renewal Vault cannot answer is retried, then ends the lease before it runs out")
    func failedRenewalEnds() async throws {
        let clock = ManualClock()
        let renewer = RecordingRenewer([.failure(VaultError.unreachable("https://vault.test", "offline"))])
        let endings = EndingRecorder()
        let lease = VaultLease(leaseId: "l1", grant: grant(60), renewable: true, renewer: renewer, clock: clock)

        lease.start { endings.record($0) }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(40))
        try await waitUntil { renewer.renewalCount == 1 }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))
        try await waitUntil { renewer.renewalCount == 2 }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))
        try await waitUntil { lease.hasEnded }

        #expect(renewer.renewalCount == 2)
        #expect(endings.endings.count == 1)
        lease.release()
    }

    @Test("A lease Vault no longer knows ends at once, so the connection signs in again before the user is gone")
    func revokedLeaseEndsAtOnce() async throws {
        let clock = ManualClock()
        let renewer = RecordingRenewer([.failure(VaultRequestError(status: 400, messages: ["lease not found"]))])
        let lease = VaultLease(leaseId: "l1", grant: grant(3_600), renewable: true, renewer: renewer, clock: clock)

        lease.start { _ in }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(2_400))

        try await waitUntil { lease.hasEnded }
        #expect(renewer.renewalCount == 1)
        lease.release()
    }

    @Test("Which renewal failures are worth a retry", arguments: [
        (VaultRequestError(status: 400, messages: ["lease not found"]) as any Error, true),
        (VaultRequestError(status: 403, messages: ["permission denied"]) as any Error, true),
        (VaultRequestError(status: 429, messages: []) as any Error, false),
        (VaultRequestError(status: 503, messages: ["sealed"]) as any Error, false),
        (VaultError.unreachable("https://vault.test", "offline") as any Error, false),
        (VaultError.oidcSignInRequired(VaultOIDCLogin(endpoint: VaultFixtures.endpoint, mount: "oidc", role: "")) as any Error, true),
    ])
    func definitiveFailures(error: any Error, definitive: Bool) {
        #expect(VaultLease.isDefinitive(error) == definitive)
    }

    @Test("A slow renewal spends the lease's time, so no retry runs past the lead")
    func slowRenewalCountsAgainstTheLease() async throws {
        let clock = ManualClock()
        let renewer = SlowFailingRenewer(clock: clock)
        let lease = VaultLease(leaseId: "l1", grant: grant(60), renewable: true, renewer: renewer, clock: clock)

        lease.start { _ in }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(40))

        try await waitUntil { lease.hasEnded }
        #expect(renewer.timeouts == [.seconds(10)])
        lease.release()
    }

    @Test("Releasing revokes once and stops renewing")
    func releaseRevokesOnce() async throws {
        let clock = ManualClock()
        let renewer = RecordingRenewer([.success(grant(60))])
        let endings = EndingRecorder()
        let lease = VaultLease(leaseId: "l1", grant: grant(60), renewable: true, renewer: renewer, clock: clock)
        lease.start { endings.record($0) }
        await clock.waitUntilSleeping()

        lease.release()
        lease.release()
        try await waitUntil { renewer.revokedLeases == ["l1"] }
        clock.advance(by: .seconds(120))

        #expect(renewer.renewalCount == 0)
        #expect(endings.endings.isEmpty)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("A lease nobody holds any more is revoked, so a connect that timed out leaves no user behind")
    func droppedLeaseRevokes() async throws {
        let renewer = RecordingRenewer([.success(grant(60))])
        var lease: VaultLease? = VaultLease(
            leaseId: "orphan",
            grant: grant(60),
            renewable: true,
            renewer: renewer,
            clock: ManualClock()
        )
        lease?.start { _ in }
        #expect(lease?.hasEnded == false)
        lease = nil

        try await waitUntil { renewer.revokedLeases == ["orphan"] }
    }
}
