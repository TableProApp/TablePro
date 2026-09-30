//
//  LibSSH2TunnelFactory.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

import TableProSSHTransport

/// Credentials needed for SSH tunnel creation
internal struct SSHTunnelCredentials: Sendable {
    let sshPassword: String?
    let keyPassphrase: String?
    let totpSecret: String?
    let keyboardInteractivePromptProvider: (any KeyboardInteractivePromptProvider)?
}

/// Creates fully-connected and authenticated SSH tunnels using libssh2.
internal enum LibSSH2TunnelFactory {
    internal static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2TunnelFactory")

    /// A single session opens more than one connection through the tunnel: the query
    /// connection plus the metadata pool. A backlog that cannot hold them resets the
    /// overflow before the accept loop reaches it.
    private static let listenBacklogSize: Int32 = 16

    // MARK: - Global Init

    /// libssh2's own header says `libssh2_init` uses global state and must not be called
    /// concurrently, so every entry point in the process goes through this one lazy static.
    internal static let initialized: Bool = {
        libssh2_init(0)
        return true
    }()

    // MARK: - Public

    static func createTunnel(
        connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        destination: SSHForwardDestination,
        localPort: Int,
        deadline: ConnectionDeadline
    ) async throws -> LibSSH2Tunnel {
        _ = initialized
        let endpoint = timeoutEndpoint(host: config.host, port: config.port ?? 22)
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: endpoint)
        let watchdog = attempt.startWatchdog()
        defer {
            watchdog.cancel()
            attempt.finish()
        }

        return try await withTaskCancellationHandler {
            let chain = try await buildAuthenticatedChain(
                config: config,
                credentials: credentials,
                queueLabel: "com.TablePro.ssh.hop.\(connectionId.uuidString)",
                deadline: deadline,
                attempt: attempt
            )

            do {
                try probeForwardDestination(
                    session: chain.session,
                    socketFD: chain.socketFD,
                    destination: destination,
                    deadline: deadline,
                    attempt: attempt
                )

                let listenFD = try bindListenSocket(port: localPort)
                do {
                    try attempt.check(for: endpoint)
                } catch {
                    Darwin.close(listenFD)
                    throw error
                }

                let tunnel = LibSSH2Tunnel(
                    connectionId: connectionId,
                    localPort: localPort,
                    session: chain.session,
                    socketFD: chain.socketFD,
                    listenFD: listenFD,
                    connectionDeadline: deadline,
                    timeoutEndpoint: chain.timeoutEndpoint,
                    jumpChain: chain.jumpHops.map { hop in
                        LibSSH2Tunnel.JumpHop(
                            session: hop.session,
                            socket: hop.socket,
                            channel: hop.channel,
                            relayTask: hop.relayTask
                        )
                    }
                )

                logger.info(
                    "Tunnel created: \(config.host) -> 127.0.0.1:\(localPort) -> \(destination.logDescription)"
                )

                attempt.finish()
                return tunnel
            } catch {
                attempt.finish()
                cleanupChain(chain, reason: "Error")
                throw error
            }
        } onCancel: {
            attempt.cancel()
        }
    }

    /// Test SSH connectivity without creating a full tunnel.
    /// Connects, performs handshake, verifies host key, authenticates, then cleans up.
    static func testConnection(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        deadline: ConnectionDeadline
    ) async throws {
        _ = initialized
        let endpoint = timeoutEndpoint(host: config.host, port: config.port ?? 22)
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: endpoint)
        let watchdog = attempt.startWatchdog()
        defer {
            watchdog.cancel()
            attempt.finish()
        }

        try await withTaskCancellationHandler {
            let chain = try await buildAuthenticatedChain(
                config: config,
                credentials: credentials,
                queueLabel: "com.TablePro.ssh.test-hop",
                deadline: deadline,
                attempt: attempt
            )
            try attempt.check(for: endpoint)
            attempt.finish()
            logger.info("SSH test connection successful to \(config.host)")
            cleanupChain(chain, reason: "Test complete")
        } onCancel: {
            attempt.cancel()
        }
    }

    // MARK: - Shared Chain Builder

    /// Result of building an authenticated SSH chain (possibly through jump hosts).
    internal struct AuthenticatedChain {
        let session: OpaquePointer
        let socketFD: Int32
        let timeoutEndpoint: ConnectionTimeoutEndpoint
        let jumpHops: [HopInfo]

        struct HopInfo {
            let session: OpaquePointer
            let socket: Int32
            let channel: OpaquePointer
            let relayTask: Task<Void, Never>?
        }
    }

    /// The depth ssh itself stops at, so a `Host a / ProxyJump b` plus `Host b / ProxyJump a` pair
    /// ends rather than recursing until the stack runs out.
    private static let maxJumpChainDepth = 10

    /// Resolves the hops in order, following each one's own `ProxyJump` first. A jump host may
    /// declare a jump host of its own, and ssh walks that recursively: for `target` -> `bee` ->
    /// `ay`, it connects to `ay`, tunnels to `bee`, then reaches `target`. Reading only the
    /// target's own `ProxyJump` stopped the chain at `bee`, which is either unreachable or the
    /// wrong host entirely.
    internal static func resolveJumpChain(
        _ jumpHosts: [SSHJumpHost],
        document: SSHConfigDocument,
        env: ResolverEnvironment = .live,
        depth: Int = 0
    ) -> [ResolvedSSHTarget] {
        guard depth < maxJumpChainDepth else {
            logger.warning("SSH ProxyJump chain deeper than \(maxJumpChainDepth) hops, stopping")
            return []
        }

        return jumpHosts.flatMap { jumpHost -> [ResolvedSSHTarget] in
            let resolved = SSHConfigResolver.resolve(jumpHost, document: document, env: env)
            let earlier = resolveJumpChain(
                resolved.proxyJump,
                document: document,
                env: env,
                depth: depth + 1
            )
            return earlier + [resolved]
        }
    }

    internal static func buildAuthenticatedChain(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        queueLabel: String,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) async throws -> AuthenticatedChain {
        _ = initialized

        let configuredEndpoint = timeoutEndpoint(host: config.host, port: config.port ?? 22)
        try attempt.prepare(for: configuredEndpoint)

        let document = await SSHConfigCache.shared.current()
        try attempt.check(for: configuredEndpoint)
        let resolved = try resolveChainConfiguration(config: config, document: document)
        let resolvedPrimary = resolved.primary
        let resolvedJumps = resolved.jumps

        let firstHop = resolvedJumps.first ?? resolvedPrimary
        let firstEndpoint = timeoutEndpoint(host: firstHop.host, port: firstHop.port)
        let socketFD = try await connectTCP(
            host: firstHop.host,
            port: firstHop.port,
            deadline: deadline,
            attempt: attempt
        )

        do {
            let session = try createSession(
                socketFD: socketFD,
                endpoint: firstEndpoint,
                deadline: deadline,
                attempt: attempt
            )
            var jumpHops: [AuthenticatedChain.HopInfo] = []
            var currentSession = session
            var currentSocketFD = socketFD

            do {
                try await verifyHostKey(
                    session: session,
                    hostname: firstHop.host,
                    port: firstHop.port,
                    attempt: attempt
                )

                try authenticateFirstHop(
                    config: config,
                    credentials: credentials,
                    resolved: resolved,
                    session: session,
                    socketFD: socketFD,
                    endpoint: firstEndpoint,
                    deadline: deadline,
                    attempt: attempt
                )

                if !resolvedJumps.isEmpty {
                    for jumpIndex in 0..<resolvedJumps.count {
                        let nextResolved: ResolvedSSHTarget = jumpIndex + 1 < resolvedJumps.count
                            ? resolvedJumps[jumpIndex + 1]
                            : resolvedPrimary
                        let nextEndpoint = timeoutEndpoint(host: nextResolved.host, port: nextResolved.port)

                        let channel = try openChannel(
                            session: currentSession,
                            socketFD: currentSocketFD,
                            remoteHost: nextResolved.host,
                            remotePort: nextResolved.port,
                            endpoint: nextEndpoint,
                            deadline: deadline,
                            attempt: attempt
                        )

                        var fds: [Int32] = [0, 0]
                        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                            libssh2_channel_free(channel)
                            throw SSHTunnelError.tunnelCreationFailed("Failed to create socketpair")
                        }

                        let hopSessionQueue = DispatchQueue(
                            label: "\(queueLabel).\(jumpIndex)",
                            qos: .utility
                        )

                        let relayTask = startChannelRelay(
                            channel: channel,
                            socketFD: fds[0],
                            sshSocketFD: currentSocketFD,
                            session: currentSession,
                            sessionQueue: hopSessionQueue
                        )

                        let hop = AuthenticatedChain.HopInfo(
                            session: currentSession,
                            socket: currentSocketFD,
                            channel: channel,
                            relayTask: relayTask
                        )
                        jumpHops.append(hop)

                        let nextSession: OpaquePointer
                        do {
                            nextSession = try createSession(
                                socketFD: fds[1],
                                endpoint: nextEndpoint,
                                deadline: deadline,
                                attempt: attempt
                            )
                        } catch {
                            Darwin.close(fds[1])
                            relayTask.cancel()
                            throw error
                        }

                        do {
                            try await authenticateNextHop(
                                jumpIndex: jumpIndex,
                                config: config,
                                credentials: credentials,
                                resolved: resolved,
                                session: nextSession,
                                socketFD: fds[1],
                                endpoint: nextEndpoint,
                                deadline: deadline,
                                attempt: attempt
                            )
                        } catch {
                            // Clean up nextSession and fds[1]; relay task owns fds[0]
                            tablepro_libssh2_session_disconnect(nextSession, "Error")
                            libssh2_session_free(nextSession)
                            Darwin.close(fds[1])
                            relayTask.cancel()
                            throw error
                        }

                        currentSession = nextSession
                        currentSocketFD = fds[1]
                    }
                }

                return AuthenticatedChain(
                    session: currentSession,
                    socketFD: currentSocketFD,
                    timeoutEndpoint: timeoutEndpoint(
                        host: resolvedPrimary.host,
                        port: resolvedPrimary.port
                    ),
                    jumpHops: jumpHops
                )
            } catch {
                attempt.clearTransportInterrupt()
                // Clean up currentSession if it differs from all hop sessions
                // (happens when a nextSession was created but failed auth/verify)
                let sessionInHops = jumpHops.contains { $0.session == currentSession }
                if !sessionInHops {
                    tablepro_libssh2_session_disconnect(currentSession, "Error")
                    libssh2_session_free(currentSession)
                    if currentSocketFD != socketFD {
                        Darwin.close(currentSocketFD)
                    }
                }

                // Clean up any jump hops that were created (reverse order).
                // Shutdown sockets first to break relay loops, then free resources.
                for hop in jumpHops.reversed() {
                    hop.relayTask?.cancel()
                    shutdown(hop.socket, SHUT_RDWR)
                }
                for hop in jumpHops.reversed() {
                    libssh2_channel_free(hop.channel)
                    tablepro_libssh2_session_disconnect(hop.session, "Error")
                    libssh2_session_free(hop.session)
                    Darwin.close(hop.socket)
                }

                throw error
            }
        } catch {
            attempt.clearTransportInterrupt()
            Darwin.close(socketFD)
            throw error
        }
    }

    private struct ResolvedChainConfiguration {
        let primary: ResolvedSSHTarget
        let jumps: [ResolvedSSHTarget]
        let formJumps: [SSHJumpHost]
    }

    private static func resolveChainConfiguration(
        config: SSHConfiguration,
        document: SSHConfigDocument
    ) throws -> ResolvedChainConfiguration {
        let primary = SSHConfigResolver.resolve(config, document: document)
        let formJumps = config.jumpHosts
        let jumps = resolveJumpChain(
            formJumps.isEmpty ? primary.proxyJump : formJumps,
            document: document
        )

        for target in [primary] + jumps {
            if let failure = target.expansionFailure {
                throw SSHTunnelError.configExpansionFailed(failure.explanation)
            }
        }
        guard !primary.username.isEmpty else {
            throw SSHTunnelError.usernameMissing(host: config.host)
        }
        return ResolvedChainConfiguration(primary: primary, jumps: jumps, formJumps: formJumps)
    }

    private static func authenticateFirstHop(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        resolved: ResolvedChainConfiguration,
        session: OpaquePointer,
        socketFD: Int32,
        endpoint: ConnectionTimeoutEndpoint,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) throws {
        if let firstJump = resolved.jumps.first {
            let authenticator = try buildJumpAuthenticator(
                jumpHost: resolved.formJumps.first ?? SSHJumpHost(),
                resolved: firstJump,
                attempt: attempt,
                timeoutEndpoint: endpoint
            )
            try authenticate(
                authenticator,
                session: session,
                socketFD: socketFD,
                username: firstJump.username,
                endpoint: endpoint,
                deadline: deadline,
                attempt: attempt
            )
            return
        }

        let authenticator = try buildAuthenticator(
            config: config,
            resolved: resolved.primary,
            credentials: credentials,
            attempt: attempt,
            timeoutEndpoint: endpoint
        )
        try authenticate(
            authenticator,
            session: session,
            socketFD: socketFD,
            username: resolved.primary.username,
            endpoint: endpoint,
            deadline: deadline,
            attempt: attempt
        )
    }

    private static func authenticateNextHop(
        jumpIndex: Int,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        resolved: ResolvedChainConfiguration,
        session: OpaquePointer,
        socketFD: Int32,
        endpoint: ConnectionTimeoutEndpoint,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) async throws {
        let nextTarget = jumpIndex + 1 < resolved.jumps.count
            ? resolved.jumps[jumpIndex + 1]
            : resolved.primary
        try await verifyHostKey(
            session: session,
            hostname: nextTarget.host,
            port: nextTarget.port,
            attempt: attempt
        )

        if jumpIndex + 1 < resolved.jumps.count {
            let nextFormJump = resolved.formJumps.indices.contains(jumpIndex + 1)
                ? resolved.formJumps[jumpIndex + 1]
                : SSHJumpHost()
            let authenticator = try buildJumpAuthenticator(
                jumpHost: nextFormJump,
                resolved: nextTarget,
                attempt: attempt,
                timeoutEndpoint: endpoint
            )
            try authenticate(
                authenticator,
                session: session,
                socketFD: socketFD,
                username: nextTarget.username,
                endpoint: endpoint,
                deadline: deadline,
                attempt: attempt
            )
            return
        }

        let authenticator = try buildAuthenticator(
            config: config,
            resolved: resolved.primary,
            credentials: credentials,
            attempt: attempt,
            timeoutEndpoint: endpoint
        )
        try authenticate(
            authenticator,
            session: session,
            socketFD: socketFD,
            username: resolved.primary.username,
            endpoint: endpoint,
            deadline: deadline,
            attempt: attempt
        )
    }

    /// Clean up all resources in an authenticated chain.
    internal static func cleanupChain(_ chain: AuthenticatedChain, reason: String) {
        tablepro_libssh2_session_disconnect(chain.session, reason)
        libssh2_session_free(chain.session)
        Darwin.close(chain.socketFD)

        // Clean up jump hops in reverse order:
        // First pass: cancel relays and shutdown sockets to break relay loops
        for hop in chain.jumpHops.reversed() {
            hop.relayTask?.cancel()
            shutdown(hop.socket, SHUT_RDWR)
        }
        // Second pass: free channels, sessions, and close sockets
        // Note: relay task owns fds[0] via defer, so we only close hop.socket
        // (which is the SSH socket for that hop, not the relay socketpair fd)
        for hop in chain.jumpHops.reversed() {
            libssh2_channel_free(hop.channel)
            tablepro_libssh2_session_disconnect(hop.session, reason)
            libssh2_session_free(hop.session)
            Darwin.close(hop.socket)
        }
    }

    // MARK: - Session

    private static func createSession(
        socketFD: Int32,
        endpoint: ConnectionTimeoutEndpoint,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) throws -> OpaquePointer {
        try attempt.prepare(for: endpoint)
        guard let session = tablepro_libssh2_session_init() else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to initialize libssh2 session")
        }

        _ = attempt.registerTransportInterrupt {
            shutdown(socketFD, SHUT_RDWR)
        }
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, max(1, deadline.remainingMilliseconds))

        let rc = libssh2_session_handshake(session, socketFD)
        if rc != 0 {
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            libssh2_session_free(session)
            do {
                try attempt.check(for: endpoint)
            } catch {
                throw error
            }
            if rc == LIBSSH2_ERROR_TIMEOUT {
                throw deadline.timeoutError(for: endpoint)
            }
            throw SSHTunnelError.tunnelCreationFailed("SSH handshake failed: \(detail)")
        }

        do {
            try attempt.check(for: endpoint)
        } catch {
            libssh2_session_free(session)
            throw error
        }
        return session
    }

    // MARK: - Host Key Verification

    private static func verifyHostKey(
        session: OpaquePointer,
        hostname: String,
        port: Int,
        attempt: SSHConnectionAttempt
    ) async throws {
        var keyLength = 0
        var keyType: Int32 = 0
        guard let keyPtr = libssh2_session_hostkey(session, &keyLength, &keyType) else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to get host key")
        }

        let keyData = Data(bytes: keyPtr, count: keyLength)
        let keyTypeName = HostKeyStore.keyTypeName(keyType)

        try await HostKeyVerifier.verify(
            keyData: keyData,
            keyType: keyTypeName,
            hostname: hostname,
            port: port,
            attempt: attempt
        )
    }

    // MARK: - Authentication

    private static func authenticate(
        _ authenticator: any SSHAuthenticator,
        session: OpaquePointer,
        socketFD: Int32,
        username: String,
        endpoint: ConnectionTimeoutEndpoint,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) throws {
        try attempt.prepare(for: endpoint)
        _ = attempt.registerTransportInterrupt {
            shutdown(socketFD, SHUT_RDWR)
        }
        libssh2_session_set_timeout(session, max(1, deadline.remainingMilliseconds))

        do {
            try authenticator.authenticate(session: session, username: username)
        } catch {
            do {
                try attempt.check(for: endpoint)
            } catch {
                throw error
            }
            if libssh2_session_last_errno(session) == LIBSSH2_ERROR_TIMEOUT {
                throw deadline.timeoutError(for: endpoint)
            }
            throw error
        }
        try attempt.check(for: endpoint)
    }

    internal static func buildAuthenticator(
        config: SSHConfiguration,
        resolved: ResolvedSSHTarget,
        credentials: SSHTunnelCredentials,
        attempt: SSHConnectionAttempt? = nil,
        timeoutEndpoint: ConnectionTimeoutEndpoint? = nil
    ) throws -> any SSHAuthenticator {
        let promptProvider = credentials.keyboardInteractivePromptProvider ?? PromptKeyboardInteractiveProvider(
            attempt: attempt,
            timeoutEndpoint: timeoutEndpoint
        )

        switch config.authMethod {
        case .password:
            // Always pair password with a keyboard-interactive fallback that reuses the same
            // password. Servers that only advertise `keyboard-interactive` (e.g. PAM stacks
            // using google-authenticator, which prompt `Password:` over kbd-int) reject the
            // bare `password` method, and falling through here matches OpenSSH's and
            // Sequel Ace's behavior.
            guard let sshPassword = credentials.sshPassword else {
                logger.error("SSH password is nil (Keychain lookup may have failed) for \(resolved.host)")
                throw SSHTunnelError.authenticationFailed(reason: .passwordMissing)
            }
            return CompositeAuthenticator(authenticators: [
                PasswordAuthenticator(password: sshPassword),
                KeyboardInteractiveAuthenticator(
                    password: sshPassword,
                    totpProvider: buildTOTPProvider(config: config, credentials: credentials),
                    promptProvider: promptProvider
                ),
            ])

        case .privateKey:
            let keyPaths = effectiveKeyPaths(for: resolved)
            guard !keyPaths.isEmpty else {
                throw SSHTunnelError.authenticationFailed(reason: .privateKey)
            }
            var authenticators: [any SSHAuthenticator] = keyPaths.map { keyPath in
                buildKeyFileAuthenticator(
                    keyPath: keyPath,
                    providedPassphrase: credentials.keyPassphrase,
                    resolved: resolved,
                    attempt: attempt,
                    timeoutEndpoint: timeoutEndpoint
                )
            }
            authenticators.append(KeyboardInteractiveAuthenticator(
                password: nil,
                totpProvider: buildTOTPProvider(config: config, credentials: credentials),
                promptProvider: promptProvider
            ))
            return CompositeAuthenticator(authenticators: authenticators)

        case .sshAgent:
            // The agent is the credential, so there is no key-file fallback: authenticating with a
            // key the user never chose put TablePro's own passphrase prompt over an agent that had
            // simply not been reached (#2583). Keyboard-interactive stays, being a second factor the
            // same server asked for rather than another credential.
            let socketPath: String? = resolved.agentSocketPath.isEmpty
                ? nil
                : SSHPathUtilities.expandTilde(resolved.agentSocketPath)

            return CompositeAuthenticator(
                authenticators: [
                    AgentAuthenticator(
                        socketPath: socketPath,
                        socketOrigin: resolved.agentSocketOrigin,
                        identityFiles: resolved.identityFiles,
                        identitiesOnly: resolved.identitiesOnly
                    ),
                    KeyboardInteractiveAuthenticator(
                        password: nil,
                        totpProvider: buildTOTPProvider(config: config, credentials: credentials),
                        promptProvider: promptProvider
                    ),
                ],
                endsChainOn: Set(
                    AgentSocketOrigin.allCases.map(AuthFailureReason.agentUnavailable)
                        + AgentSocketOrigin.allCases.map(AuthFailureReason.agentNoIdentities)
                        + AgentSocketOrigin.allCases.map(AuthFailureReason.agentNoMatchingIdentity)
                        + [.agentIdentityFileUnreadable, .agentServerClosedConnection]
                )
            )

        case .keyboardInteractive:
            return KeyboardInteractiveAuthenticator(
                password: credentials.sshPassword,
                totpProvider: buildTOTPProvider(config: config, credentials: credentials),
                promptProvider: promptProvider
            )

        case .none:
            return NoneAuthenticator()
        }
    }

    private static func effectiveKeyPaths(for resolved: ResolvedSSHTarget) -> [String] {
        if !resolved.identityFiles.isEmpty {
            return resolved.identityFiles
        }
        if resolved.identitiesOnly {
            return []
        }
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        return ["id_ed25519", "id_rsa", "id_ecdsa"]
            .map { sshDir.appendingPathComponent($0).path }
            .filter { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Passphrase resolution is deferred to auth time (not build time) so that a key later in
    /// the chain only prompts once the ones before it have actually been refused.
    private static func buildKeyFileAuthenticator(
        keyPath: String,
        providedPassphrase: String?,
        resolved: ResolvedSSHTarget,
        attempt: SSHConnectionAttempt?,
        timeoutEndpoint: ConnectionTimeoutEndpoint?
    ) -> any SSHAuthenticator {
        KeyFileAuthenticator(
            keyPath: keyPath,
            providedPassphrase: providedPassphrase,
            useKeychain: resolved.useKeychain,
            addKeysToAgent: resolved.addKeysToAgent,
            attempt: attempt,
            timeoutEndpoint: timeoutEndpoint
        )
    }

    /// Authenticator that resolves the passphrase at AUTH time (not build time),
    /// then delegates to PublicKeyAuthenticator. Saves to Keychain and adds to
    /// agent only after authentication succeeds.
    private struct KeyFileAuthenticator: SSHAuthenticator {
        let keyPath: String
        let providedPassphrase: String?
        let useKeychain: Bool
        let addKeysToAgent: Bool
        let attempt: SSHConnectionAttempt?
        let timeoutEndpoint: ConnectionTimeoutEndpoint?

        func authenticate(session: OpaquePointer, username: String) throws {
            let expandedPath = SSHPathUtilities.expandTilde(keyPath)

            // 1. Try with stored passphrase or nil (covers unencrypted keys + Keychain hits)
            let storedPassphrase = SSHPassphraseResolver.resolve(
                forKeyAt: keyPath,
                provided: providedPassphrase,
                useKeychain: useKeychain
            )
            let firstAttempt = PublicKeyAuthenticator(
                privateKeyPath: keyPath,
                passphrase: storedPassphrase
            )
            do {
                try firstAttempt.authenticate(session: session, username: username)
                addToAgentIfNeeded(path: expandedPath)
                return
            } catch {
                // A wire-level rejection (or a partial success the server accepted as one
                // factor of publickey,keyboard-interactive) reports AUTHENTICATION_FAILED. No
                // passphrase can change that, so rethrow instead of prompting; any other errno
                // means the local key file needs a passphrase we don't have yet.
                guard libssh2_session_last_errno(session) != LIBSSH2_ERROR_AUTHENTICATION_FAILED else {
                    throw error
                }
            }

            // 2. Prompt the user (key is encrypted, no stored passphrase)
            let provider = PromptPassphraseProvider(
                keyPath: expandedPath,
                attempt: attempt,
                timeoutEndpoint: timeoutEndpoint
            )
            guard let promptResult = try provider.providePassphrase() else {
                throw SSHTunnelError.authenticationFailed(reason: .privateKey)
            }

            let retryAuth = PublicKeyAuthenticator(
                privateKeyPath: keyPath,
                passphrase: promptResult.passphrase
            )
            try retryAuth.authenticate(session: session, username: username)

            // Auth succeeded — save to Keychain if user opted in
            if promptResult.saveToKeychain && useKeychain {
                SSHKeychainLookup.savePassphrase(promptResult.passphrase, forKeyAt: expandedPath)
            }
            addToAgentIfNeeded(path: expandedPath)
        }

        private func addToAgentIfNeeded(path: String) {
            guard addKeysToAgent else { return }
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
                // Use --apple-use-keychain so ssh-add reads the passphrase from
                // Keychain for encrypted keys (no TTY available in GUI apps)
                process.arguments = ["--apple-use-keychain", path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
    }

    private static func buildJumpAuthenticator(
        jumpHost: SSHJumpHost,
        resolved: ResolvedSSHTarget,
        attempt: SSHConnectionAttempt?,
        timeoutEndpoint: ConnectionTimeoutEndpoint?
    ) throws -> any SSHAuthenticator {
        switch jumpHost.authMethod {
        case .privateKey:
            let keyPaths = effectiveKeyPaths(for: resolved)
            guard !keyPaths.isEmpty else {
                throw SSHTunnelError.authenticationFailed(reason: .privateKey)
            }
            let authenticators = keyPaths.map { path in
                KeyFileAuthenticator(
                    keyPath: path,
                    providedPassphrase: nil,
                    useKeychain: resolved.useKeychain,
                    addKeysToAgent: resolved.addKeysToAgent,
                    attempt: attempt,
                    timeoutEndpoint: timeoutEndpoint
                )
            }
            return authenticators.count == 1
                ? authenticators[0]
                : CompositeAuthenticator(authenticators: authenticators)
        case .sshAgent:
            let socketPath: String? = resolved.agentSocketPath.isEmpty ? nil : resolved.agentSocketPath
            let agent = AgentAuthenticator(
                socketPath: socketPath,
                socketOrigin: resolved.agentSocketOrigin,
                identityFiles: resolved.identityFiles,
                identitiesOnly: resolved.identitiesOnly
            )
            if !jumpHost.privateKeyPath.isEmpty {
                let keyAuth = KeyFileAuthenticator(
                    keyPath: jumpHost.privateKeyPath,
                    providedPassphrase: nil,
                    useKeychain: resolved.useKeychain,
                    addKeysToAgent: resolved.addKeysToAgent,
                    attempt: attempt,
                    timeoutEndpoint: timeoutEndpoint
                )
                return CompositeAuthenticator(authenticators: [agent, keyAuth])
            }
            return agent
        }
    }

    private static func buildTOTPProvider(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) -> (any TOTPProvider)? {
        guard config.totpMode == .autoGenerate else { return nil }
        guard let secret = credentials.totpSecret,
              let generator = TOTPGenerator.fromBase32Secret(
                  secret,
                  algorithm: config.totpAlgorithm.toGeneratorAlgorithm,
                  digits: config.totpDigits,
                  period: config.totpPeriod
              ) else {
            return nil
        }
        return AutoTOTPProvider(generator: generator)
    }

    // MARK: - Channel Operations

    /// Confirms the SSH server can actually reach the forward destination before a tunnel port
    /// is handed back. Creating a tunnel otherwise only proves the SSH hop works: a destination
    /// the server cannot reach stays invisible until the database driver dials the local port,
    /// where it surfaces as an accepted socket that goes silent and the driver reports as a
    /// greeting timeout naming no cause (#1981). Covers TCP as well as sockets, because the
    /// common case is a database bound to 127.0.0.1 behind a host field holding the server's
    /// public address, which no amount of driver-side timeout tuning can explain to the user.
    /// Bounded by the same deadline and poll pattern a per-client open uses, so a destination
    /// that never answers cannot hang tunnel creation.
    private static func probeForwardDestination(
        session: OpaquePointer,
        socketFD: Int32,
        destination: SSHForwardDestination,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) throws {
        let endpoint = ConnectionTimeoutEndpoint.tunnel(destination.logDescription)
        try attempt.prepare(for: endpoint)
        _ = attempt.registerTransportInterrupt {
            shutdown(socketFD, SHUT_RDWR)
        }
        let probeQueue = DispatchQueue(label: "com.TablePro.ssh.probe")
        probeQueue.sync { libssh2_session_set_blocking(session, 0) }
        defer { probeQueue.sync { libssh2_session_set_blocking(session, 1) } }

        let pump = SSHForwardChannelOpenPump(
            opener: LibSSH2ForwardChannelOpener(
                session: session,
                destination: destination,
                originPort: 0,
                sessionQueue: probeQueue
            ),
            isActive: { !deadline.isExpired && !Task.isCancelled },
            deadline: .distantFuture,
            pollForReadiness: { directions in
                pollReady(
                    fd: socketFD,
                    directions: directions,
                    timeoutMs: Int32(clamping: max(1, deadline.remainingMilliseconds))
                )
            }
        )

        let outcome = pump.run()
        if case .opened(let channel) = outcome {
            probeQueue.sync {
                libssh2_channel_close(channel)
                libssh2_channel_free(channel)
            }
            try attempt.check(for: endpoint)
            return
        }

        try attempt.check(for: endpoint)

        let error = outcome.forwardFailure(
            destination: destination,
            deadlineSeconds: deadline.configuredSeconds
        )?.tunnelError ?? SSHTunnelError.channelOpenFailed
        logger.error("Forward probe to \(destination.logDescription) failed: \(error.localizedDescription)")
        throw error
    }

    private static func openChannel(
        session: OpaquePointer,
        socketFD: Int32,
        remoteHost: String,
        remotePort: Int,
        endpoint: ConnectionTimeoutEndpoint,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) throws -> OpaquePointer {
        try attempt.prepare(for: endpoint)
        _ = attempt.registerTransportInterrupt {
            shutdown(socketFD, SHUT_RDWR)
        }
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, max(1, deadline.remainingMilliseconds))
        defer { libssh2_session_set_blocking(session, 0) }

        let channel = libssh2_channel_direct_tcpip_ex(
            session,
            remoteHost,
            Int32(remotePort),
            "127.0.0.1",
            0
        )
        guard let channel else {
            do {
                try attempt.check(for: endpoint)
            } catch {
                throw error
            }
            if libssh2_session_last_errno(session) == LIBSSH2_ERROR_TIMEOUT {
                throw deadline.timeoutError(for: endpoint)
            }
            throw SSHTunnelError.channelOpenFailed
        }

        do {
            try attempt.check(for: endpoint)
        } catch {
            libssh2_channel_free(channel)
            throw error
        }
        return channel
    }

    internal static func timeoutEndpoint(host: String, port: Int) -> ConnectionTimeoutEndpoint {
        .tunnel("\(host):\(port)")
    }

    /// The libssh2 handles the relay task takes ownership of. The relay is the only thing that
    /// touches them once it starts, which is what the compiler cannot see through an OpaquePointer.
    private struct RelayHandles: @unchecked Sendable {
        let channel: OpaquePointer
        let session: OpaquePointer
    }

    /// Start a relay task that copies data between a channel and a socketpair fd.
    /// libssh2 calls use `sessionQueue.sync` for thread safety; I/O loop runs on a concurrent queue.
    private static func startChannelRelay(
        channel: OpaquePointer,
        socketFD: Int32,
        sshSocketFD: Int32,
        session: OpaquePointer,
        sessionQueue: DispatchQueue
    ) -> Task<Void, Never> {
        let relayQueue = DispatchQueue(
            label: "com.TablePro.ssh.hop-relay",
            qos: .utility
        )
        let handles = RelayHandles(channel: channel, session: session)
        return Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                relayQueue.async {
                    let relay = SSHChannelRelay(
                        localFD: socketFD,
                        transportFD: sshSocketFD,
                        channelIO: LibSSH2ChannelIO(
                            channel: handles.channel,
                            session: handles.session,
                            sessionQueue: sessionQueue
                        ),
                        bufferSize: 32_768,
                        isActive: { !Task.isCancelled }
                    )

                    _ = relay.run()

                    shutdown(socketFD, SHUT_RDWR)
                    Darwin.close(socketFD)
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Local Socket

    private static func bindListenSocket(port: Int) throws -> Int32 {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to create listening socket")
        }

        var reuseAddr: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(listenFD)
            throw SSHTunnelError.tunnelCreationFailed("Port \(port) already in use")
        }

        guard listen(listenFD, Self.listenBacklogSize) == 0 else {
            Darwin.close(listenFD)
            throw SSHTunnelError.tunnelCreationFailed("Failed to listen on port \(port)")
        }
        return listenFD
    }
}

// MARK: - TOTPAlgorithm Extension

extension TOTPAlgorithm {
    var toGeneratorAlgorithm: TOTPGenerator.Algorithm {
        switch self {
        case .sha1: return .sha1
        case .sha256: return .sha256
        case .sha512: return .sha512
        }
    }
}
