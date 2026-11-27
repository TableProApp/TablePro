//
//  SSHSessionRoute.swift
//  TablePro
//

import CryptoKit
import Foundation

import TableProSSHConfig
import TableProSSHTransport

// What makes two connections' SSH sessions interchangeable: every hop as `~/.ssh/config` resolved it, how each
// signs in, the secrets the sign-in uses, and the destination the channels go to. Two connections that would sign
// in as the same user with the same key or password on every hop share one session; any difference, a stored
// password included, gets its own, so a connection never rides a sign-in its own credentials would not have made.
// The host key needs no place here: the shared session verified it against the same host and port this route names.
//
// The destination is part of it because libssh2 opens one channel at a time per session: a destination the server
// cannot reach holds its open until the server's own connect gives up, often minutes behind a firewall that drops
// the SYN, and on a session shared across destinations every other database's new connections would wait behind it.
internal struct SSHSessionRoute: Hashable, Sendable {
    struct Hop: Hashable, Sendable {
        let alias: String
        let host: String
        let dialHost: String
        let port: Int
        let username: String
        let identityFiles: [String]
        let agentSocketPath: String
        let agentSocketOrigin: AgentSocketOrigin
        let agentDisabled: Bool
        let identitiesOnly: Bool
        let useKeychain: Bool
        let addKeysToAgent: Bool
        let signIn: SignIn
    }

    enum SignIn: Hashable, Sendable {
        // A form jump host, or nil for one only `~/.ssh/config` names (it signs in through the agent).
        case jump(method: SSHJumpAuthMethod?, privateKeyPath: String)
        case target(
            method: SSHAuthMethod,
            privateKeyPath: String,
            agentSocketPath: String,
            totpMode: TOTPMode,
            totpAlgorithm: TOTPAlgorithm,
            totpDigits: Int,
            totpPeriod: Int
        )
    }

    // In dial order: the first jump host first, the SSH server last.
    let hops: [Hop]
    let destination: SSHForwardDestination
    let secretsDigest: Data

    init(
        config: SSHConfiguration,
        resolved: LibSSH2TunnelFactory.ResolvedChainConfiguration,
        credentials: SSHTunnelCredentials,
        destination: SSHForwardDestination
    ) {
        let jumps = resolved.jumps.map { jump in
            Self.hop(jump.target, signIn: .jump(
                method: jump.formHop?.authMethod,
                privateKeyPath: jump.formHop?.privateKeyPath ?? ""
            ))
        }
        let target = Self.hop(resolved.primary, signIn: .target(
            method: config.authMethod,
            privateKeyPath: config.privateKeyPath,
            agentSocketPath: config.agentSocketPath,
            totpMode: config.totpMode,
            totpAlgorithm: config.totpAlgorithm,
            totpDigits: config.totpDigits,
            totpPeriod: config.totpPeriod
        ))
        hops = jumps + [target]
        self.destination = destination
        secretsDigest = Self.digest(credentials)
    }

    static func resolve(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        destination: SSHForwardDestination
    ) async throws -> SSHSessionRoute {
        let document = await SSHConfigCache.shared.current()
        let resolved = try LibSSH2TunnelFactory.resolveChainConfiguration(config: config, document: document)
        return SSHSessionRoute(config: config, resolved: resolved, credentials: credentials, destination: destination)
    }

    private static func hop(_ target: ResolvedSSHTarget, signIn: SignIn) -> Hop {
        Hop(
            alias: target.originalHost,
            host: target.host,
            dialHost: target.dialHost,
            port: target.port,
            username: target.username,
            identityFiles: target.identityFiles,
            agentSocketPath: target.agentSocketPath,
            agentSocketOrigin: target.agentSocketOrigin,
            agentDisabled: target.agentDisabled,
            identitiesOnly: target.identitiesOnly,
            useKeychain: target.useKeychain,
            addKeysToAgent: target.addKeysToAgent,
            signIn: signIn
        )
    }

    // Kept as a digest so the registry's keys never hold a secret. Each value is length-prefixed, so no two
    // different sets of secrets run together into the same bytes.
    private static func digest(_ credentials: SSHTunnelCredentials) -> Data {
        var hasher = SHA256()
        for secret in [credentials.sshPassword, credentials.keyPassphrase, credentials.totpSecret] {
            guard let secret else {
                hasher.update(data: Data([0]))
                continue
            }
            let bytes = Data(secret.utf8)
            hasher.update(data: Data([1]))
            withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return Data(hasher.finalize())
    }
}
