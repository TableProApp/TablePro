//
//  VaultDatabaseCredentialsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

private final class TokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VaultToken] = []

    var tokens: [VaultToken] { lock.withLock { recorded } }

    func record(_ token: VaultToken) {
        lock.withLock { recorded.append(token) }
    }
}

struct VaultDatabaseCredentialsTests {
    private let role = VaultDatabaseRole(address: "https://vault.test:8200", mount: "database", role: "readonly")
    private let owner = UUID()

    private func credentials(_ transport: VaultFakeTransport, files: [String: String] = [:]) -> VaultDatabaseCredentials {
        VaultDatabaseCredentials(
            authenticator: VaultFixtures.authenticator(transport: transport, environment: ["VAULT_TOKEN": "t0"], files: files),
            transport: transport,
            clock: ManualClock()
        )
    }

    @Test("A sign-in hands back the generated username and password with the lease that owns them")
    func signsInWithGeneratedUser() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)

        let signIn = try await credentials(transport).signIn(role, owner: owner, for: nil, interactive: false)

        #expect(signIn.username == "v-token-readonly-1")
        #expect(signIn.password == "s3cret")
        let lease = try #require(signIn.lease)
        #expect(lease.leaseId == "database/creds/readonly/abc")
        lease.release()
    }

    @Test("Sign-ins for one owner and role share one lease")
    func signInsShareTheLease() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)
        let credentials = credentials(transport)

        let first = try await credentials.signIn(role, owner: owner, for: nil, interactive: false)
        first.lease?.release()
        let second = try await credentials.signIn(role, owner: owner, for: nil, interactive: false)

        #expect(transport.requests(to: "database/creds/readonly").count == 1)
        #expect(second.username == first.username)
        #expect(second.lease?.leaseId == first.lease?.leaseId)
        second.lease?.release()
    }

    @Test("Another owner signs in as a user of its own")
    func otherOwnerReadsItsOwnLease() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)
        let credentials = credentials(transport)

        let first = try await credentials.signIn(role, owner: owner, for: nil, interactive: false)
        let second = try await credentials.signIn(role, owner: UUID(), for: nil, interactive: false)

        #expect(transport.requests(to: "database/creds/readonly").count == 2)
        #expect(first.lease != second.lease)
        first.lease?.release()
        second.lease?.release()
    }

    @Test("A role Vault refuses names the path it read")
    func refusedRoleNamesPath() async {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", status: 403, #"{"errors":["1 error occurred:\n\t* permission denied\n\n"]}"#)

        await #expect(throws: VaultError.credentialsFailed(path: "database/creds/readonly", message: "permission denied")) {
            try await credentials(transport).signIn(role, owner: owner, for: nil, interactive: false)
        }
    }

    @Test("A sealed Vault reads as unreachable, so an unattended reconnect tries again", arguments: [503, 429])
    func sealedVaultIsUnreachable(status: Int) async {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", status: status, #"{"errors":["Vault is sealed"]}"#)

        await #expect(throws: VaultError.unreachable("https://vault.test:8200", "Vault is sealed")) {
            try await credentials(transport).signIn(role, owner: owner, for: nil, interactive: false)
        }
    }

    @Test("Vault's own failure names its reason and is worth another try")
    func vaultFailureNamesItsReason() async {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", status: 500, #"{"errors":["local node not active"]}"#)

        await #expect(throws: VaultError.serverFailed("local node not active")) {
            try await credentials(transport).signIn(role, owner: owner, for: nil, interactive: false)
        }
    }

    @Test("A minted token Vault no longer accepts is replaced once, not reused")
    func revokedMintedTokenLogsInAgain() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/approle/login", VaultFixtures.authReply(token: "old", ttl: 3_600))
        transport.reply("POST", "auth/approle/login", VaultFixtures.authReply(token: "new", ttl: 3_600))
        transport.reply("GET", "database/creds/readonly", status: 403, #"{"errors":["permission denied"]}"#)
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)
        var appRole = role
        appRole.auth = .appRole(mount: "approle", roleId: "r", secretIdPath: "/keys/secret-id")

        let signIn = try await credentials(transport, files: ["secret-id": "s"])
            .signIn(appRole, owner: owner, for: nil, interactive: false)

        #expect(transport.requests(to: "database/creds/readonly").map(\.token) == ["old", "new"])
        #expect(signIn.username == "v-token-readonly-1")
        signIn.lease?.release()
    }

    @Test("Ending the last connection that used a lease revokes it, with the token that issued it")
    func endUseRevokes() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        transport.reply("GET", "database/creds/readonly", VaultFixtures.credsReply)
        transport.reply("PUT", "sys/leases/revoke", status: 204, "")
        let credentials = credentials(transport)
        let connection = UUID()

        let signIn = try await credentials.signIn(role, owner: owner, for: connection, interactive: false)
        signIn.lease?.release()
        credentials.endUse(connection: connection, live: [])

        try await waitUntil { !transport.requests(to: "sys/leases/revoke").isEmpty }
        let revoke = try #require(transport.requests(to: "sys/leases/revoke").first)
        #expect(revoke.body == ["lease_id": "database/creds/readonly/abc"])
        #expect(revoke.token == "t0")
    }

    @Test("Renewal uses the token that issued the lease, renewing it first when it would expire sooner")
    func renewalUsesIssuingToken() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/token/renew-self", VaultFixtures.authReply(token: "issuer", ttl: 3_600))
        transport.reply("PUT", "sys/leases/renew", #"{"lease_duration":3600}"#)
        let now = ContinuousClock.now
        let issuer = VaultToken(value: "issuer", source: .appRole, expiresAt: now + .seconds(60), renewable: true)
        let renewer = IssuingTokenLeaseRenewer(
            client: VaultClient(endpoint: VaultFixtures.endpoint, transport: transport),
            token: issuer,
            now: { now }
        )

        let grant = try await renewer.renew(leaseId: "l1", increment: .seconds(3_600), timeout: .seconds(30))

        #expect(transport.requests.map { $0.path } == ["auth/token/renew-self", "sys/leases/renew"])
        #expect(transport.requests.allSatisfy { $0.token == "issuer" })
        #expect(grant == VaultLeaseGrant(leaseDuration: .seconds(3_600), tokenRemaining: .seconds(3_600)))
    }

    @Test("A renewed issuing token reaches the shared cache, so the next sign-in does not throw it away")
    func renewedTokenIsShared() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/token/renew-self", VaultFixtures.authReply(token: "issuer", ttl: 3_600))
        transport.reply("PUT", "sys/leases/renew", #"{"lease_duration":3600}"#)
        let now = ContinuousClock.now
        let issuer = VaultToken(value: "issuer", source: .oidc, expiresAt: now + .seconds(60), renewable: true)
        let shared = TokenRecorder()
        let renewer = IssuingTokenLeaseRenewer(
            client: VaultClient(endpoint: VaultFixtures.endpoint, transport: transport),
            token: issuer,
            now: { now },
            onTokenRenewed: { shared.record($0) }
        )

        _ = try await renewer.renew(leaseId: "l1", increment: .seconds(3_600), timeout: .seconds(30))

        #expect(shared.tokens.map { $0.value } == ["issuer"])
        #expect(shared.tokens.first?.grantedTTL == .seconds(3_600))
    }

    @Test("A short-lived token is kept as it is, and a long one past most of its life is not", arguments: [
        (Int64(120), Int64(100), false),
        (Int64(3_600), Int64(200), true),
        (Int64(3_600), Int64(1_000), false),
    ])
    func nearItsEnd(granted: Int64, remaining: Int64, nearEnd: Bool) {
        let now = ContinuousClock.now
        let token = VaultToken(
            value: "t",
            source: .oidc,
            expiresAt: now + .seconds(remaining),
            renewable: false,
            grantedTTL: .seconds(granted)
        )
        #expect(token.isNearItsEnd(at: now, floor: VaultDatabaseCredentials.minimumTokenLife) == nearEnd)
    }

    @Test("Only a token TablePro minted bounds the lease's schedule")
    func boundingLife() {
        let now = ContinuousClock.now
        let userToken = VaultToken(value: "u", source: .tokenFile, expiresAt: now + .seconds(60), renewable: false)
        let minted = VaultToken(value: "m", source: .appRole, expiresAt: now + .seconds(60), renewable: true)

        #expect(VaultDatabaseCredentials.boundingLife(of: userToken, at: now) == nil)
        #expect(VaultDatabaseCredentials.boundingLife(of: minted, at: now) == .seconds(60))
    }
}
