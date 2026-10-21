//
//  VaultDatabaseCredentials.swift
//  TablePro
//

import Foundation
import os

// Every call reads a new lease. The credential lives only in the returned value and the driver it configures.
struct VaultDatabaseCredentials: Sendable {
    static let shared = VaultDatabaseCredentials()

    // A lease dies with the token that created it, so a minted token close to its end is renewed or replaced first.
    static let minimumTokenLife: Duration = .seconds(300)

    private let authenticator: VaultAuthenticator
    private let transport: any VaultTransport
    private let clock: any Clock<Duration>

    init(
        authenticator: VaultAuthenticator = .shared,
        transport: any VaultTransport = URLSessionVaultTransport.shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.authenticator = authenticator
        self.transport = transport
        self.clock = clock
    }

    func signIn(_ role: VaultDatabaseRole, interactive: Bool) async throws -> ResolvedSignIn {
        let endpoint = try VaultEndpoint.resolve(address: role.address, environment: authenticator.currentEnvironment)
        let client = VaultClient(endpoint: endpoint, transport: transport)
        let path = role.credentialsPath

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
            throw VaultError.credentialsFailed(path: path, message: error.message)
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
        return ResolvedSignIn(username: credential.username, password: credential.password, lease: lease)
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
            throw VaultError.credentialsFailed(path: path, message: error.message)
        }
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
