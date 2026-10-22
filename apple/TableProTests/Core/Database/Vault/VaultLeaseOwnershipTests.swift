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

private final class RevokeRecorder: VaultLeaseRenewing, @unchecked Sendable {
    private let lock = NSLock()
    private var revoked: [String] = []

    var revokedLeases: [String] { lock.withLock { revoked } }

    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant {
        throw VaultRequestError(status: 400, messages: ["lease not found"])
    }

    func revoke(leaseId: String) async {
        lock.withLock { revoked.append(leaseId) }
    }
}

@MainActor
struct VaultLeaseOwnershipTests {
    private func lease(_ recorder: RevokeRecorder, clock: ManualClock, seconds: Int64 = 3_600) -> VaultLease {
        VaultLease(
            leaseId: "database/creds/ro/1",
            grant: VaultLeaseGrant(leaseDuration: .seconds(seconds), tokenRemaining: nil),
            renewable: false,
            renewer: recorder,
            clock: clock
        )
    }

    @Test("A driver revokes the lease it signed in with when it disconnects")
    func disconnectRevokes() async throws {
        let recorder = RevokeRecorder()
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: SilentPluginDriver(),
            credentialLease: lease(recorder, clock: ManualClock())
        )

        adapter.disconnect()
        adapter.disconnect()

        try await waitUntil { recorder.revokedLeases == ["database/creds/ro/1"] }
    }

    @Test("A driver whose lease ended reports its connection lost, so pooled work opens a fresh one")
    func endedLeaseIsLostConnection() async throws {
        let recorder = RevokeRecorder()
        let clock = ManualClock()
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(),
            pluginDriver: SilentPluginDriver(),
            credentialLease: lease(recorder, clock: clock, seconds: 60)
        )
        #expect(!adapter.hasLostConnection)

        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(50))

        try await waitUntil { adapter.hasLostConnection }
        adapter.disconnect()
    }
}
