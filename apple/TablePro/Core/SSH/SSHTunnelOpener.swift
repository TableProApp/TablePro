//
//  SSHTunnelOpener.swift
//  TablePro
//

import Foundation

import TableProSSHConfig
import TableProSSHTransport

internal typealias SSHSessions = SSHSessionRegistry<SSHSessionRoute, LibSSH2SharedSession>

internal enum SSHTunnelOpener {
    // Binds the local port before any sign-in, so a port collision never repeats the host key, passphrase or
    // TOTP step, then takes the route's shared session, signing in only when no connection holds one yet, and
    // checks the destination with the channel the first client will use.
    static func open(
        connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        destination: SSHForwardDestination,
        sessions: SSHSessions,
        localPortCandidates: () -> [Int],
        deadline: ConnectionDeadline,
        onDeath: @escaping @Sendable (LibSSH2Tunnel) -> Void
    ) async throws -> LibSSH2Tunnel {
        let route = try await SSHSessionRoute.resolve(config: config, credentials: credentials, destination: destination)
        // A session other connections already use can have died a moment before the keep-alive noticed; its first
        // open then fails on the transport, and one fresh session is worth trying before reporting anything.
        var mayRetryOnFreshSession = true
        while true {
            let listener = try LibSSH2TunnelFactory.bindLocalListener(candidates: localPortCandidates())
            let lease: SSHSessions.Lease
            do {
                lease = try await acquireSession(
                    route: route,
                    connectionId: connectionId,
                    config: config,
                    credentials: credentials,
                    sessions: sessions,
                    deadline: deadline
                )
            } catch {
                Darwin.close(listener.descriptor)
                throw error
            }

            let token = lease.token
            let tunnel = LibSSH2Tunnel(
                connectionId: connectionId,
                localPort: listener.port,
                listenFD: listener.descriptor,
                session: lease.session,
                leaseId: token,
                connectionDeadline: deadline,
                releaseLease: { Task { await sessions.release(route, token: token) } },
                onDeath: onDeath
            )
            do {
                try Task.checkCancellation()
                try await tunnel.openFirstChannel(destination: destination)
                return tunnel
            } catch {
                tunnel.close()
                if mayRetryOnFreshSession, lease.reused, !lease.session.isRunning, !deadline.isExpired, !Task.isCancelled {
                    mayRetryOnFreshSession = false
                    continue
                }
                throw error
            }
        }
    }

    // A sign-in this connection joined runs under the deadline of the connection that started it. When that one
    // runs out first, this connection still has time of its own and starts the sign-in again.
    private static func acquireSession(
        route: SSHSessionRoute,
        connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        sessions: SSHSessions,
        deadline: ConnectionDeadline
    ) async throws -> SSHSessions.Lease {
        let endpoint = LibSSH2TunnelFactory.timeoutEndpoint(host: config.host, port: config.port ?? 22)
        while true {
            do {
                return try await sessions.acquire(
                    route,
                    deadline: deadline.instant,
                    timedOut: { deadline.timeoutError(for: endpoint) }
                ) {
                    let session = try await LibSSH2TunnelFactory.createSharedSession(
                        config: config,
                        credentials: credentials,
                        deadline: deadline,
                        label: connectionId.uuidString
                    )
                    session.addDeathHandler(id: UUID()) {
                        Task { await sessions.forget(route, session: session) }
                    }
                    return session
                }
            } catch is ConnectionTimeoutError where !deadline.isExpired && !Task.isCancelled {
                continue
            }
        }
    }
}
