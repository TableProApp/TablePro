//
//  AgentAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

internal struct AgentAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AgentAuthenticator")

    /// `MaxAuthTries` ends in an `SSH_MSG_DISCONNECT`, which `_libssh2_packet_add` answers by
    /// setting `socket_state` and returning `LIBSSH2_ERROR_SOCKET_DISCONNECT`. That code is the
    /// only one here on purpose: libssh2's agent backend reports its own socket failures as
    /// `LIBSSH2_ERROR_SOCKET_SEND` and `LIBSSH2_ERROR_SOCKET_RECV`, so an agent that quit
    /// mid-signing is indistinguishable from a server that hung up if either is included, and it
    /// only ever returns `SOCKET_DISCONNECT` from `agent_disconnect_unix`, which
    /// `libssh2_agent_userauth` never reaches. A refused key is
    /// `LIBSSH2_ERROR_AUTHENTICATION_FAILED` or `LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED`, so an
    /// ordinary rejection still moves on to the next key.
    private static let serverHungUp = LIBSSH2_ERROR_SOCKET_DISCONNECT

    let socketPath: String?
    let socketOrigin: AgentSocketOrigin

    /// The `IdentityFile` entries resolved for this host, from `~/.ssh/config` or the form.
    var identityFiles: [String] = []

    /// `IdentitiesOnly yes`, which drops every agent key that no identity file named.
    var identitiesOnly: Bool = false

    /// Resolve SSH_AUTH_SOCK via launchctl for GUI apps that don't inherit shell env.
    private static func resolveSocketViaLaunchctl() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                logger.debug("Resolved SSH_AUTH_SOCK via launchctl: \(path, privacy: .private)")
                return path
            }
        } catch {
            logger.warning("Failed to resolve SSH_AUTH_SOCK via launchctl: \(error.localizedDescription)")
        }
        return nil
    }

    func authenticate(session: OpaquePointer, username: String) throws {
        // Resolve the effective socket path:
        // - Custom path: use it directly
        // - System default (nil): use process env, or fall back to launchctl
        //   (GUI apps launched from Finder may not inherit SSH_AUTH_SOCK)
        let effectivePath: String?
        if let customPath = socketPath {
            effectivePath = SSHPathUtilities.expandTilde(customPath)
        } else if ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil {
            effectivePath = nil // already set in process env
        } else {
            effectivePath = Self.resolveSocketViaLaunchctl()
        }

        guard let agent = libssh2_agent_init(session) else {
            throw SSHTunnelError.authenticationFailed(reason: .agentUnavailable(socketOrigin))
        }

        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }

        // Use libssh2's API to set the socket path directly — avoids mutating
        // the process-global SSH_AUTH_SOCK environment variable.
        if let path = effectivePath {
            Self.logger.debug("Setting agent socket path: \(path, privacy: .private)")
            path.withCString { cPath in
                libssh2_agent_set_identity_path(agent, cPath)
            }
        }

        var rc = libssh2_agent_connect(agent)
        guard rc == 0 else {
            Self.logger.error("Failed to connect to SSH agent (rc=\(rc))")
            throw SSHTunnelError.authenticationFailed(reason: .agentUnavailable(socketOrigin))
        }

        rc = libssh2_agent_list_identities(agent)
        guard rc == 0 else {
            Self.logger.error("Failed to list SSH agent identities (rc=\(rc))")
            throw SSHTunnelError.authenticationFailed(reason: .agentUnavailable(socketOrigin))
        }

        let identities = try collectIdentities(from: agent)

        // An agent that answered but offered nothing is a locked or empty agent, which the user
        // fixes somewhere entirely different from an agent whose keys the server refused.
        guard !identities.isEmpty else {
            Self.logger.error("SSH agent offered no identities")
            throw SSHTunnelError.authenticationFailed(reason: .agentNoIdentities(socketOrigin))
        }

        let order = try offerOrder(for: identities)
        for (position, index) in order.enumerated() {
            let authRc = libssh2_agent_userauth(agent, username, identities[index])
            if authRc == 0 {
                Self.logger.info("SSH agent authentication succeeded on key \(position + 1) of \(order.count)")
                return
            }
            if authRc == Self.serverHungUp {
                Self.logger.error(
                    "SSH server closed the connection after \(position + 1) of \(order.count) agent keys (rc=\(authRc))"
                )
                throw SSHTunnelError.authenticationFailed(reason: .agentServerClosedConnection)
            }
        }

        Self.logger.error("SSH agent authentication failed: none of \(order.count) identities accepted")
        throw SSHTunnelError.authenticationFailed(reason: .agentRejected)
    }

    /// Walks the whole identity list before anything is offered, because the order to offer them
    /// in is not the order the agent lists them in. The pointers belong to the agent handle and
    /// stay valid until `libssh2_agent_free`, which the caller's `defer` runs after the last
    /// `libssh2_agent_userauth`.
    private func collectIdentities(
        from agent: OpaquePointer
    ) throws -> [UnsafeMutablePointer<libssh2_agent_publickey>] {
        var identities: [UnsafeMutablePointer<libssh2_agent_publickey>] = []
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var current: UnsafeMutablePointer<libssh2_agent_publickey>?

        while true {
            let rc = libssh2_agent_get_identity(agent, &current, previous)
            if rc == 1 {
                return identities
            }
            if rc < 0 {
                Self.logger.error("Failed to get SSH agent identity (rc=\(rc))")
                throw SSHTunnelError.authenticationFailed(reason: .agentUnavailable(socketOrigin))
            }
            guard let identity = current else {
                return identities
            }
            identities.append(identity)
            previous = identity
        }
    }

    private func offerOrder(
        for identities: [UnsafeMutablePointer<libssh2_agent_publickey>]
    ) throws -> [Int] {
        let preferred = identityFiles.flatMap { SSHPublicKeyFile.blobs(atIdentityPath: $0) }
        guard !preferred.isEmpty else { return try unfilteredOrder(for: identities) }

        let blobs = identities.map { identity -> Data in
            guard let bytes = identity.pointee.blob, identity.pointee.blob_len > 0 else { return Data() }
            return Data(bytes: bytes, count: identity.pointee.blob_len)
        }
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: blobs,
            preferred: preferred,
            identitiesOnly: identitiesOnly
        )

        guard !order.isEmpty else {
            Self.logger.error("No agent identity matches the identity files for this host")
            throw SSHTunnelError.authenticationFailed(reason: .agentNoMatchingIdentity(socketOrigin))
        }

        Self.logger.debug("Offering \(order.count) of \(identities.count) agent identities")
        return order
    }

    /// Reached when no identity file yielded a public key, which is two different situations.
    ///
    /// No identity file at all is the ordinary case: the agent's own order stands and every key is
    /// offered, exactly as before there was a preference. An identity file that named nothing
    /// readable is a configuration mistake, and quietly offering every key there would hand the
    /// user back the `MaxAuthTries` failure they set the file to avoid, with no clue why. Under
    /// `IdentitiesOnly` that is refused outright; without it, `ssh` also falls back to the rest of
    /// the agent, so the warning is the whole report.
    private func unfilteredOrder(
        for identities: [UnsafeMutablePointer<libssh2_agent_publickey>]
    ) throws -> [Int] {
        guard !identityFiles.isEmpty else { return Array(identities.indices) }

        guard !identitiesOnly else {
            Self.logger.error("IdentitiesOnly is set and no identity file yielded a public key")
            throw SSHTunnelError.authenticationFailed(reason: .agentIdentityFileUnreadable)
        }

        Self.logger.warning("No identity file yielded a public key, so every agent key is offered")
        return Array(identities.indices)
    }
}
