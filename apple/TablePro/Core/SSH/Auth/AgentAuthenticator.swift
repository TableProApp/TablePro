import Foundation
import os

import CLibSSH2
import TableProSSHConfig
import TableProSSHTransport

internal struct AgentAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AgentAuthenticator")

    let socketPath: String?
    let socketOrigin: AgentSocketOrigin

    // The `IdentityFile` entries resolved for this host, from `~/.ssh/config` or the form.
    var identityFiles: [String] = []

    // `IdentitiesOnly yes`, which drops every agent key that no identity file named.
    var identitiesOnly: Bool = false

    // An app launched from Finder does not inherit the shell's SSH_AUTH_SOCK.
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
        var unsigned = 0
        for (position, index) in order.enumerated() {
            let authRc = libssh2_agent_userauth(agent, username, identities[index])
            if authRc == 0 {
                Self.logger.info("SSH agent authentication succeeded on key \(position + 1) of \(order.count)")
                return
            }
            if authRc == LIBSSH2_ERROR_METHOD_NONE {
                unsigned += 1
            }
        }

        // No key reached the server, which an RSA key does when the server takes only ssh-rsa signatures.
        if unsigned > 0, unsigned == order.count {
            Self.logger.error("SSH agent authentication failed: no agent key has a signature the server takes")
            throw SSHTunnelError.negotiationFailed(
                .keySignature(serverBanner: LibSSH2Handshake.banner(session)),
                jumpHost: nil
            )
        }

        Self.logger.error("SSH agent authentication failed: none of \(order.count) identities accepted")
        throw SSHTunnelError.authenticationFailed(reason: .agentRejected)
    }

    // Walks the whole identity list before anything is offered, because the order to offer them
    // in is not the order the agent lists them in. The pointers belong to the agent handle and
    // stay valid until `libssh2_agent_free`, which the caller's `defer` runs after the last
    // `libssh2_agent_userauth`.
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

    // No identity file at all leaves the agent's own order. An identity file that named nothing
    // readable is a configuration mistake, and offering every key there would hand back the
    // `MaxAuthTries` failure the file was set to avoid. Under `IdentitiesOnly` that is refused;
    // without it, `ssh` also falls back to the rest of the agent, so the warning is the whole report.
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
