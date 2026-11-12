//
//  VaultDatabaseCredentials.swift
//  TablePro
//

import Foundation
import os

// The credential lives only in memory: in the cached lease and the drivers that sign in with it.
struct VaultDatabaseCredentials: Sendable {
    static let shared = VaultDatabaseCredentials()

    // A lease dies with the token that created it, so a minted token close to its end is renewed or replaced first.
    static let minimumTokenLife: Duration = .seconds(300)
    // Quit waits this long for Vault to revoke the users still leased.
    static let quitRevokeLimit: Duration = .seconds(3)

    private let authenticator: VaultAuthenticator
    private let transport: any VaultTransport
    private let clock: any Clock<Duration>
    private let leases: VaultLeaseCache

    init<C: Clock<Duration>>(
        authenticator: VaultAuthenticator = .shared,
        transport: any VaultTransport = URLSessionVaultTransport.shared,
        clock: C = ContinuousClock()
    ) {
        self.authenticator = authenticator
        self.transport = transport
        self.clock = clock
        self.leases = VaultLeaseCache(clock: clock)
    }

    // `owner` is the credential profile, or the connection for a role of its own. One owner signs in as one user
    // while its lease lives. `connection` is the one signing in, nil for a test of the source alone.
    func signIn(
        _ role: VaultDatabaseRole,
        owner: UUID,
        for connection: UUID?,
        interactive: Bool
    ) async throws -> ResolvedSignIn {
        let endpoint = try VaultEndpoint.resolve(address: role.address, environment: authenticator.currentEnvironment)
        let client = VaultClient(endpoint: endpoint, transport: transport)

        var token = try await authenticator.token(
            for: role.auth,
            endpoint: endpoint,
            interactive: interactive,
            validFor: Self.minimumTokenLife
        )
        if token.source.isMinted, token.isNearItsEnd(at: authenticator.currentInstant, floor: Self.minimumTokenLife) {
            await authenticator.forget(role.auth, endpoint: endpoint)
            token = try await authenticator.token(for: role.auth, endpoint: endpoint, interactive: interactive)
        }
        let key = VaultLeaseCache.Key(owner: owner, role: role, endpoint: endpoint, token: token.value)
        let issuing = token
        let hold = try await leases.acquire(key, for: connection) {
            try await readLease(role, endpoint: endpoint, client: client, token: issuing, interactive: interactive)
        }
        return ResolvedSignIn(username: hold.username, password: hold.password, lease: hold)
    }

    func endUse(connection: UUID, live: Set<UUID>) {
        leases.endUse(connection: connection, live: live)
    }

    func revokeAllLeases() async {
        await leases.revokeAll(within: Self.quitRevokeLimit)
    }

    private func readLease(
        _ role: VaultDatabaseRole,
        endpoint: VaultEndpoint,
        client: VaultClient,
        token initialToken: VaultToken,
        interactive: Bool
    ) async throws -> VaultLeaseCache.Issued {
        let path = role.credentialsPath
        var token = initialToken
        let credential: VaultLeasedCredential
        let issuedAt: ContinuousClock.Instant
        do {
            credential = try await client.readCredentials(path: path, token: token.value)
            issuedAt = authenticator.currentInstant
        } catch let error as VaultRequestError where error.isPermissionDenied && token.source.isMinted {
            // A minted token an admin revoked is still in the cache; log in once more before giving up.
            await authenticator.forget(role.auth, endpoint: endpoint)
            token = try await authenticator.token(for: role.auth, endpoint: endpoint, interactive: interactive)
            credential = try await Self.read(path: path, token: token.value, client: client)
            issuedAt = authenticator.currentInstant
        } catch let error as VaultRequestError {
            throw Self.failure(error, path: path, client: client)
        }

        if token.source.isMinted,
           let covering = try? await authenticator.token(
               for: role.auth,
               endpoint: endpoint,
               interactive: false,
               validFor: credential.leaseDuration
           ),
           covering.value == token.value {
            token = covering
        }

        let renewer = IssuingTokenLeaseRenewer(
            client: client,
            token: token,
            now: { [authenticator] in authenticator.currentInstant },
            onTokenRenewed: { [authenticator, auth = role.auth] renewed in
                await authenticator.adopt(renewed, for: auth, endpoint: endpoint)
            }
        )
        let now = authenticator.currentInstant
        let lease = VaultLease(
            leaseId: credential.leaseId,
            grant: VaultLeaseGrant(
                leaseDuration: credential.leaseDuration - issuedAt.duration(to: now),
                tokenRemaining: Self.boundingLife(of: token, at: now)
            ),
            increment: credential.leaseDuration,
            renewable: credential.renewable,
            renewer: renewer,
            clock: clock
        )
        return VaultLeaseCache.Issued(
            username: credential.username,
            password: credential.password,
            lease: lease,
            token: token.value
        )
    }

    // Only a token TablePro minted bounds the lease's schedule. The user's own token is theirs to renew; rotating
    // ahead of it would only mint more leases on the same expiring token.
    static func boundingLife(of token: VaultToken, at now: ContinuousClock.Instant) -> Duration? {
        token.source.isMinted ? token.remaining(at: now) : nil
    }

    private static func read(path: String, token: String, client: VaultClient) async throws -> VaultLeasedCredential {
        do {
            return try await client.readCredentials(path: path, token: token)
        } catch let error as VaultRequestError {
            throw failure(error, path: path, client: client)
        }
    }

    private static func failure(_ error: VaultRequestError, path: String, client: VaultClient) -> VaultError {
        .signInFailure(error, at: client.endpoint, otherwise: .credentialsFailed(path: path, message: error.message))
    }
}

// Renews and revokes with the token that issued the lease: Vault revokes a lease with that token, whatever token
// the cache holds by then.
final class IssuingTokenLeaseRenewer: VaultLeaseRenewing {
    private let client: VaultClient
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onTokenRenewed: @Sendable (VaultToken) async -> Void
    private let issuing: OSAllocatedUnfairLock<VaultToken>

    private static let logger = Logger(subsystem: "com.TablePro", category: "VaultLease")

    init(
        client: VaultClient,
        token: VaultToken,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        onTokenRenewed: @escaping @Sendable (VaultToken) async -> Void = { _ in }
    ) {
        self.client = client
        self.now = now
        self.onTokenRenewed = onTokenRenewed
        self.issuing = OSAllocatedUnfairLock(initialState: token)
    }

    // `timeout` covers both requests: the lease is spending its time while either waits.
    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant {
        let deadline = now() + timeout
        var token = issuing.withLock { $0 }
        if token.source.isMinted, token.renewable, let expiresAt = token.expiresAt, expiresAt < now() + increment,
           let grant = try? await client.renewSelf(token: token.value, increment: increment, timeout: timeout) {
            token = VaultToken(
                value: token.value,
                source: token.source,
                expiresAt: grant.ttl.map { now() + $0 },
                renewable: grant.renewable,
                grantedTTL: grant.ttl
            )
            let renewed = token
            issuing.withLock { $0 = renewed }
            await onTokenRenewed(renewed)
        }
        let left = now().duration(to: deadline)
        guard left > .zero else {
            throw VaultError.unreachable(client.endpoint.address.absoluteString, String(localized: "The request timed out."))
        }
        let granted = try await client.renewLease(id: leaseId, increment: increment, token: token.value, timeout: left)
        return VaultLeaseGrant(
            leaseDuration: granted,
            tokenRemaining: VaultDatabaseCredentials.boundingLife(of: token, at: now())
        )
    }

    // Best effort: a lease nobody can revoke still ends at its TTL, or with the token that issued it.
    func revoke(leaseId: String) async {
        do {
            try await client.revokeLease(id: leaseId, token: issuing.withLock { $0.value })
        } catch {
            Self.logger.warning("Could not revoke a Vault lease: \(error.publicLogShape, privacy: .public)")
        }
    }
}
