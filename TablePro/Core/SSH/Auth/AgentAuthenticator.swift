//
//  AgentAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

internal struct AgentAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AgentAuthenticator")

    /// Protects setenv/unsetenv of SSH_AUTH_SOCK across concurrent tunnel setups
    private static let agentSocketLock = NSLock()

    let socketPath: String?

    func authenticate(session: OpaquePointer, username: String) throws {
        // Save original SSH_AUTH_SOCK so we can restore it
        let originalSocketPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        let needsSocketOverride = socketPath != nil

        if let overridePath = socketPath.map(SSHPathUtilities.expandTilde), needsSocketOverride {
            Self.agentSocketLock.lock()
            Self.logger.debug("Using custom SSH agent socket: \(overridePath, privacy: .private)")
            setenv("SSH_AUTH_SOCK", overridePath, 1)
        }

        defer {
            if needsSocketOverride {
                // Restore original SSH_AUTH_SOCK
                if let originalSocketPath {
                    setenv("SSH_AUTH_SOCK", originalSocketPath, 1)
                } else {
                    unsetenv("SSH_AUTH_SOCK")
                }
                Self.agentSocketLock.unlock()
            }
        }

        guard let agent = libssh2_agent_init(session) else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to initialize SSH agent")
        }

        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }

        var rc = libssh2_agent_connect(agent)
        guard rc == 0 else {
            Self.logger.error("Failed to connect to SSH agent (rc=\(rc))")
            throw SSHTunnelError.tunnelCreationFailed("Failed to connect to SSH agent")
        }

        rc = libssh2_agent_list_identities(agent)
        guard rc == 0 else {
            Self.logger.error("Failed to list SSH agent identities (rc=\(rc))")
            throw SSHTunnelError.tunnelCreationFailed("Failed to list SSH agent identities")
        }

        // Iterate through available identities and try each
        var previousIdentity: UnsafeMutablePointer<libssh2_agent_publickey>?
        var currentIdentity: UnsafeMutablePointer<libssh2_agent_publickey>?

        while true {
            rc = libssh2_agent_get_identity(agent, &currentIdentity, previousIdentity)

            if rc == 1 {
                // End of identity list, none worked
                break
            }
            if rc < 0 {
                Self.logger.error("Failed to get SSH agent identity (rc=\(rc))")
                throw SSHTunnelError.tunnelCreationFailed("Failed to get SSH agent identity")
            }

            guard let identity = currentIdentity else {
                break
            }

            let authRc = libssh2_agent_userauth(agent, username, identity)
            if authRc == 0 {
                Self.logger.info("SSH agent authentication succeeded")
                return
            }

            previousIdentity = identity
        }

        Self.logger.error("SSH agent authentication failed: no identity accepted")
        throw SSHTunnelError.authenticationFailed
    }
}
