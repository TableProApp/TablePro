//
//  LibSSH2TunnelFactory.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// Credentials needed for SSH tunnel creation
internal struct SSHTunnelCredentials: Sendable {
    let sshPassword: String?
    let keyPassphrase: String?
    let totpSecret: String?
    let totpProvider: (any TOTPProvider)?
}

/// Creates fully-connected and authenticated SSH tunnels using libssh2.
internal enum LibSSH2TunnelFactory {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2TunnelFactory")

    private static let connectionTimeout: Int32 = 10 // seconds

    // MARK: - Global Init

    private static let initialized: Bool = {
        libssh2_init(0)
        return true
    }()

    // MARK: - Public

    static func createTunnel(
        connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        remoteHost: String,
        remotePort: Int,
        localPort: Int
    ) async throws -> LibSSH2Tunnel {
        _ = initialized

        let chain = try await buildAuthenticatedChain(
            config: config,
            credentials: credentials,
            queueLabel: "com.TablePro.ssh.hop.\(connectionId.uuidString)"
        )

        do {
            // Bind local listening socket
            let listenFD = try bindListenSocket(port: localPort)

            let tunnel = LibSSH2Tunnel(
                connectionId: connectionId,
                localPort: localPort,
                session: chain.session,
                socketFD: chain.socketFD,
                listenFD: listenFD,
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
                "Tunnel created: \(config.host):\(config.port) -> 127.0.0.1:\(localPort) -> \(remoteHost):\(remotePort)"
            )

            return tunnel
        } catch {
            cleanupChain(chain, reason: "Error")
            throw error
        }
    }

    /// Test SSH connectivity without creating a full tunnel.
    /// Connects, performs handshake, verifies host key, authenticates, then cleans up.
    static func testConnection(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) async throws {
        _ = initialized

        let chain = try await buildAuthenticatedChain(
            config: config,
            credentials: credentials,
            queueLabel: "com.TablePro.ssh.test-hop"
        )

        logger.info("SSH test connection successful to \(config.host):\(config.port)")
        cleanupChain(chain, reason: "Test complete")
    }

    // MARK: - Shared Chain Builder

    /// Result of building an authenticated SSH chain (possibly through jump hosts).
    private struct AuthenticatedChain {
        let session: OpaquePointer
        let socketFD: Int32
        let initialSocketFD: Int32
        let jumpHops: [HopInfo]

        struct HopInfo {
            let session: OpaquePointer
            let socket: Int32
            let channel: OpaquePointer
            let relayTask: Task<Void, Never>?
        }
    }

    /// Connects to the SSH server (possibly through jump hosts), verifies host keys,
    /// and authenticates at each hop. Returns the final authenticated session.
    private static func buildAuthenticatedChain(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        queueLabel: String
    ) async throws -> AuthenticatedChain {
        let targetHost: String
        let targetPort: Int

        if let firstJump = config.jumpHosts.first {
            targetHost = firstJump.host
            targetPort = firstJump.port
        } else {
            targetHost = config.host
            targetPort = config.port
        }

        let socketFD = try connectTCP(host: targetHost, port: targetPort)

        do {
            let session = try createSession(socketFD: socketFD)
            var jumpHops: [AuthenticatedChain.HopInfo] = []
            var currentSession = session
            var currentSocketFD = socketFD

            do {
                // Verify host key
                try await verifyHostKey(session: session, hostname: targetHost, port: targetPort)

                // Authenticate first hop
                if let firstJump = config.jumpHosts.first {
                    let jumpAuthenticator = try buildJumpAuthenticator(jumpHost: firstJump)
                    try jumpAuthenticator.authenticate(session: session, username: firstJump.username)
                } else {
                    let authenticator = try buildAuthenticator(config: config, credentials: credentials)
                    try authenticator.authenticate(session: session, username: config.username)
                }

                if !config.jumpHosts.isEmpty {
                    let jumps = config.jumpHosts

                    for jumpIndex in 0..<jumps.count {
                        // Determine next hop target
                        let nextHost: String
                        let nextPort: Int

                        if jumpIndex + 1 < jumps.count {
                            nextHost = jumps[jumpIndex + 1].host
                            nextPort = jumps[jumpIndex + 1].port
                        } else {
                            nextHost = config.host
                            nextPort = config.port
                        }

                        // Open direct-tcpip channel to next hop
                        let channel = try openChannel(
                            session: currentSession,
                            socketFD: currentSocketFD,
                            remoteHost: nextHost,
                            remotePort: nextPort
                        )

                        // Create socketpair for the next session
                        var fds: [Int32] = [0, 0]
                        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                            libssh2_channel_free(channel)
                            throw SSHTunnelError.tunnelCreationFailed("Failed to create socketpair")
                        }

                        // Each hop's session needs its own serial queue for libssh2 calls
                        let hopSessionQueue = DispatchQueue(
                            label: "\(queueLabel).\(jumpIndex)",
                            qos: .utility
                        )

                        // Start relay between channel and fds[0]
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

                        // Create new session on fds[1]
                        let nextSession: OpaquePointer
                        do {
                            nextSession = try createSession(socketFD: fds[1])
                        } catch {
                            Darwin.close(fds[1])
                            relayTask.cancel()
                            throw error
                        }

                        do {
                            // Verify host key for next hop
                            try await verifyHostKey(session: nextSession, hostname: nextHost, port: nextPort)

                            // Authenticate next hop
                            if jumpIndex + 1 < jumps.count {
                                let nextJump = jumps[jumpIndex + 1]
                                let jumpAuth = try buildJumpAuthenticator(jumpHost: nextJump)
                                try jumpAuth.authenticate(session: nextSession, username: nextJump.username)
                            } else {
                                // Final hop is the actual SSH server
                                let authenticator = try buildAuthenticator(
                                    config: config,
                                    credentials: credentials
                                )
                                try authenticator.authenticate(
                                    session: nextSession,
                                    username: config.username
                                )
                            }
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
                    initialSocketFD: socketFD,
                    jumpHops: jumpHops
                )
            } catch {
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
            Darwin.close(socketFD)
            throw error
        }
    }

    /// Clean up all resources in an authenticated chain.
    private static func cleanupChain(_ chain: AuthenticatedChain, reason: String) {
        // Disconnect the final session
        tablepro_libssh2_session_disconnect(chain.session, reason)
        libssh2_session_free(chain.session)
        if chain.socketFD != chain.initialSocketFD {
            Darwin.close(chain.socketFD)
        }

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

    // MARK: - TCP Connection

    private static func connectTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let rc = getaddrinfo(host, portString, &hints, &result)

        guard rc == 0, let firstAddr = result else {
            let errorMsg = rc != 0 ? String(cString: gai_strerror(rc)) : "No address found"
            throw SSHTunnelError.tunnelCreationFailed("DNS resolution failed for \(host): \(errorMsg)")
        }
        defer { freeaddrinfo(result) }

        // Iterate through all addresses returned by getaddrinfo
        var currentAddr: UnsafeMutablePointer<addrinfo>? = firstAddr
        var lastError: String = "No address found"

        while let addrInfo = currentAddr {
            let fd = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
            guard fd >= 0 else {
                currentAddr = addrInfo.pointee.ai_next
                continue
            }

            // Set non-blocking for connection timeout
            let flags = fcntl(fd, F_GETFL, 0)
            fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let connectResult = connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)

            if connectResult != 0 && errno != EINPROGRESS {
                Darwin.close(fd)
                lastError = "Connection to \(host):\(port) failed"
                currentAddr = addrInfo.pointee.ai_next
                continue
            }

            if connectResult != 0 {
                // Wait for connection with timeout using poll()
                var writePollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&writePollFD, 1, connectionTimeout * 1_000)

                if pollResult <= 0 {
                    Darwin.close(fd)
                    lastError = "Connection timed out"
                    currentAddr = addrInfo.pointee.ai_next
                    continue
                }

                // Check for connection error
                var socketError: Int32 = 0
                var errorLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen)

                if socketError != 0 {
                    Darwin.close(fd)
                    lastError = "Connection to \(host):\(port) failed: \(String(cString: strerror(socketError)))"
                    currentAddr = addrInfo.pointee.ai_next
                    continue
                }
            }

            // Restore blocking mode for handshake/auth
            fcntl(fd, F_SETFL, flags)

            // Enable OS-level TCP keepalive so the kernel detects dead connections
            // (e.g., silent NAT gateway timeout on AWS) independently of libssh2's
            // application-level keepalive. macOS uses TCP_KEEPALIVE for the idle
            // interval (seconds before the first keepalive probe).
            var yes: Int32 = 1
            if setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                logger.warning("Failed to set SO_KEEPALIVE: \(String(cString: strerror(errno)))")
            }
            var keepIdle: Int32 = 60
            if setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                logger.warning("Failed to set TCP_KEEPALIVE: \(String(cString: strerror(errno)))")
            }

            logger.debug("TCP connected to \(host):\(port)")
            return fd
        }

        throw SSHTunnelError.tunnelCreationFailed(lastError)
    }

    // MARK: - Session

    private static func createSession(socketFD: Int32) throws -> OpaquePointer {
        guard let session = tablepro_libssh2_session_init() else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to initialize libssh2 session")
        }

        libssh2_session_set_blocking(session, 1)

        let rc = libssh2_session_handshake(session, socketFD)
        if rc != 0 {
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            libssh2_session_free(session)
            throw SSHTunnelError.tunnelCreationFailed("SSH handshake failed: \(detail)")
        }

        return session
    }

    // MARK: - Host Key Verification

    private static func verifyHostKey(
        session: OpaquePointer,
        hostname: String,
        port: Int
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
            port: port
        )
    }

    // MARK: - Authentication

    private static func buildAuthenticator(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) throws -> any SSHAuthenticator {
        switch config.authMethod {
        case .password where config.totpMode != .none:
            // Guard: nil password means the Keychain lookup failed
            guard let sshPassword = credentials.sshPassword else {
                logger.error("SSH password is nil (Keychain lookup may have failed) for \(config.host)")
                throw SSHTunnelError.authenticationFailed
            }
            let totpProvider = buildTOTPProvider(config: config, credentials: credentials)
            return CompositeAuthenticator(authenticators: [
                PasswordAuthenticator(password: sshPassword),
                KeyboardInteractiveAuthenticator(password: nil, totpProvider: totpProvider),
            ])

        case .password:
            guard let sshPassword = credentials.sshPassword else {
                logger.error("SSH password is nil (Keychain lookup may have failed) for \(config.host)")
                throw SSHTunnelError.authenticationFailed
            }
            return PasswordAuthenticator(password: sshPassword)

        case .privateKey:
            let primary = PublicKeyAuthenticator(
                privateKeyPath: config.privateKeyPath,
                passphrase: credentials.keyPassphrase
            )
            if config.totpMode != .none {
                let totpAuth = KeyboardInteractiveAuthenticator(
                    password: nil,
                    totpProvider: buildTOTPProvider(config: config, credentials: credentials)
                )
                return CompositeAuthenticator(authenticators: [primary, totpAuth])
            }
            return primary

        case .sshAgent:
            let socketPath = config.agentSocketPath.isEmpty ? nil : config.agentSocketPath
            var authenticators: [any SSHAuthenticator] = [AgentAuthenticator(socketPath: socketPath)]

            // Fallback: try key file if agent has no loaded identities
            if let keyPath = resolveIdentityFile(config: config) {
                authenticators.append(PublicKeyAuthenticator(
                    privateKeyPath: keyPath,
                    passphrase: credentials.keyPassphrase
                ))
            }

            if config.totpMode != .none {
                authenticators.append(KeyboardInteractiveAuthenticator(
                    password: nil,
                    totpProvider: buildTOTPProvider(config: config, credentials: credentials)
                ))
            }

            return authenticators.count == 1
                ? authenticators[0]
                : CompositeAuthenticator(authenticators: authenticators)

        case .keyboardInteractive:
            let totpProvider = buildTOTPProvider(config: config, credentials: credentials)
            return KeyboardInteractiveAuthenticator(
                password: credentials.sshPassword,
                totpProvider: totpProvider
            )
        }
    }

    private static func buildJumpAuthenticator(jumpHost: SSHJumpHost) throws -> any SSHAuthenticator {
        switch jumpHost.authMethod {
        case .privateKey:
            return PublicKeyAuthenticator(
                privateKeyPath: jumpHost.privateKeyPath,
                passphrase: nil
            )
        case .sshAgent:
            let agent = AgentAuthenticator(socketPath: nil)
            if !jumpHost.privateKeyPath.isEmpty {
                let keyAuth = PublicKeyAuthenticator(
                    privateKeyPath: jumpHost.privateKeyPath,
                    passphrase: nil
                )
                return CompositeAuthenticator(authenticators: [agent, keyAuth])
            }
            return agent
        }
    }

    /// Resolve an identity file path for agent auth fallback.
    /// Priority: user-configured path > ~/.ssh/config IdentityFile > default key paths.
    private static func resolveIdentityFile(config: SSHConfiguration) -> String? {
        if !config.privateKeyPath.isEmpty {
            return config.privateKeyPath
        }

        if let entry = SSHConfigParser.findEntry(for: config.host),
           let identityFile = entry.identityFile,
           !identityFile.isEmpty {
            return identityFile
        }

        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        let defaultPaths = [
            sshDir.appendingPathComponent("id_ed25519").path,
            sshDir.appendingPathComponent("id_rsa").path,
            sshDir.appendingPathComponent("id_ecdsa").path
        ]
        for path in defaultPaths {
            if FileManager.default.isReadableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func buildTOTPProvider(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) -> (any TOTPProvider)? {
        switch config.totpMode {
        case .none:
            return nil
        case .autoGenerate:
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
        case .promptAtConnect:
            return credentials.totpProvider ?? PromptTOTPProvider()
        }
    }

    // MARK: - Channel Operations

    private static func openChannel(
        session: OpaquePointer,
        socketFD: Int32,
        remoteHost: String,
        remotePort: Int
    ) throws -> OpaquePointer {
        // Use blocking mode for channel open during setup
        libssh2_session_set_blocking(session, 1)
        defer { libssh2_session_set_blocking(session, 0) }

        guard let channel = libssh2_channel_direct_tcpip_ex(
            session,
            remoteHost,
            Int32(remotePort),
            "127.0.0.1",
            0
        ) else {
            throw SSHTunnelError.channelOpenFailed
        }

        return channel
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
        return Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                relayQueue.async {
                    let bufferSize = 32_768
                    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
                    defer {
                        buffer.deallocate()
                        Darwin.close(socketFD)
                        continuation.resume()
                    }

                    while !Task.isCancelled {
                        var pollFDs = [
                            pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0),
                            pollfd(fd: sshSocketFD, events: Int16(POLLIN), revents: 0),
                        ]

                        let pollResult = poll(&pollFDs, 2, 500)
                        if pollResult < 0 { break }

                        // Channel -> socketpair (serialized libssh2 call)
                        if pollFDs[1].revents & Int16(POLLIN) != 0 || pollResult == 0 {
                            let channelRead: Int = sessionQueue.sync {
                                Int(tablepro_libssh2_channel_read(channel, buffer, bufferSize))
                            }
                            if channelRead > 0 {
                                var totalSent = 0
                                while totalSent < channelRead {
                                    let sent = send(
                                        socketFD,
                                        buffer.advanced(by: totalSent),
                                        channelRead - totalSent,
                                        0
                                    )
                                    if sent <= 0 { return }
                                    totalSent += sent
                                }
                            } else if channelRead == 0
                                || sessionQueue.sync(execute: { libssh2_channel_eof(channel) }) != 0 {
                                return
                            } else if channelRead != Int(LIBSSH2_ERROR_EAGAIN) {
                                return
                            }
                        }

                        // Socketpair -> channel
                        if pollFDs[0].revents & Int16(POLLIN) != 0 {
                            let socketRead = recv(socketFD, buffer, bufferSize, 0)
                            if socketRead <= 0 { return }

                            var totalWritten = 0
                            while totalWritten < Int(socketRead) {
                                let written: Int = sessionQueue.sync {
                                    Int(tablepro_libssh2_channel_write(
                                        channel,
                                        buffer.advanced(by: totalWritten),
                                        Int(socketRead) - totalWritten
                                    ))
                                }
                                if written > 0 {
                                    totalWritten += written
                                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                                    var writePollFD = pollfd(
                                        fd: sshSocketFD, events: Int16(POLLOUT), revents: 0
                                    )
                                    _ = poll(&writePollFD, 1, 1_000)
                                } else {
                                    return
                                }
                            }
                        }
                    }
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

        guard listen(listenFD, 5) == 0 else {
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
