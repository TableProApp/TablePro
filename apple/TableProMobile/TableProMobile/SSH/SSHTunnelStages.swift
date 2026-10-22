import CLibSSH2
import Foundation
import os
import TableProCoreTypes
import TableProDatabase
import TableProSSHTransport

// A protocol so the factory's hand-over guarantee is testable without an SSH server.
nonisolated protocol SSHTunnelStages: Sendable {
    associatedtype Tunnel: Sendable

    func connect(host: String, port: Int) async throws

    // Opens a channel from the current session to the next host; the next handshake runs over it.
    func jump(toHost host: String, port: Int) async throws

    func handshake() async throws
    func hostKey() async throws -> (keyData: Data, keyType: String)
    // `then` is the keyboard-interactive step that follows the method, as on the Mac; nil for a jump host.
    func authenticatePassword(username: String, password: String, then secondStep: KeyboardInteractiveCredentials) async throws
    func authenticatePublicKey(
        username: String,
        keyPath: String,
        passphrase: String?,
        then secondStep: KeyboardInteractiveCredentials?
    ) async throws
    func authenticatePublicKeyFromMemory(
        username: String,
        keyContent: String,
        passphrase: String?,
        then secondStep: KeyboardInteractiveCredentials?
    ) async throws
    func authenticateKeyboardInteractive(username: String, with credentials: KeyboardInteractiveCredentials) async throws
    func authenticateNone(username: String) async throws
    func beginForwarding(destination: SSHForwardDestination) async throws -> Tunnel

    /// Releases whatever has been built so far, once. Safe to call at any step, including after
    /// `beginForwarding`, where it closes the tunnel that took the resources over.
    func discard()
}

// Every step runs on the current session's queue through `runCancellableBlocking`, so a cancelled
// step returns at once and its late result is freed on that queue. Each session gets its own queue:
// a hop's relay feeds the next handshake, and one shared queue would leave them waiting on each other.
nonisolated final class LibSSH2TunnelStages: SSHTunnelStages, @unchecked Sendable {
    typealias Tunnel = SSHTunnel

    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnelStages")
    private static let connectTimeoutSeconds: Int32 = 10
    private static let blockingCallTimeoutMilliseconds = 15_000

    /// macOS documents 16 because one session carries the query connection plus the metadata
    /// pool, and iOS opens the same two.
    private static let listenBacklog: Int32 = 16
    private static let portAttempts = 20
    private static let ephemeralPorts = 49_152 ... 65_535

    /// A libssh2 session pointer on its way across a queue boundary. `OpaquePointer` is not
    /// `Sendable`, and the serial `sessionQueue` is what keeps this one safe, so the box says
    /// so rather than every call site repeating `nonisolated(unsafe)`.
    private struct SessionHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private struct ChannelHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private struct CurrentSession: Sendable {
        let handle: SessionHandle
        let queue: DispatchQueue
    }

    private enum ConnectAttempt {
        case connected(Int32)
        case failed(String)
    }

    // The listening socket is absent: nothing between binding it and the hand-over can throw.
    private struct Resources {
        var sessionQueue: DispatchQueue
        var socketFD: Int32 = -1
        var session: SessionHandle?
        var hops: [SSHJumpHop] = []
        var tunnel: SSHTunnel?
    }

    private let resources: OSAllocatedUnfairLock<Resources>
    private let discarded = TeardownLatch()

    init() {
        resources = OSAllocatedUnfairLock(initialState: Resources(sessionQueue: Self.makeSessionQueue()))
    }

    // MARK: - Steps

    func connect(host: String, port: Int) async throws {
        let queue = resources.withLock { $0.sessionQueue }
        let fd = try await runCancellableBlocking(
            on: queue,
            work: { try Self.openSocket(host: host, port: port) },
            discardLateResult: { Darwin.close($0) }
        )
        resources.withLock { $0.socketFD = fd }
        Self.logger.debug("TCP connected to \(host, privacy: .private):\(port)")
    }

    func jump(toHost host: String, port: Int) async throws {
        let current = try currentSession()
        let channel = try await runCancellableBlocking(
            on: current.queue,
            work: { ChannelHandle(pointer: try Self.openJumpChannel(session: current.handle.pointer, host: host, port: port)) },
            discardLateResult: { libssh2_channel_free($0.pointer) }
        )

        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            let reason = String(cString: strerror(errno))
            current.queue.async { libssh2_channel_free(channel.pointer) }
            throw SSHTunnelError.channelOpenFailed("\(host):\(port): \(reason)")
        }

        let relayFD = fds[0]
        let nextTransportFD = fds[1]
        let transportFD = resources.withLock { $0.socketFD }
        let relay = LibSSH2JumpRelay.start(
            channel: channel.pointer,
            localFD: relayFD,
            transportFD: transportFD,
            session: current.handle.pointer,
            sessionQueue: current.queue
        )
        let hop = SSHJumpHop(
            session: current.handle.pointer,
            socketFD: transportFD,
            channel: channel.pointer,
            relay: relay,
            sessionQueue: current.queue
        )

        resources.withLock { state in
            state.hops.append(hop)
            state.session = nil
            state.socketFD = nextTransportFD
            state.sessionQueue = Self.makeSessionQueue()
        }
        Self.logger.debug("Channel open to \(host, privacy: .private):\(port) through a jump host")
    }

    func handshake() async throws {
        let (socketFD, queue) = resources.withLock { ($0.socketFD, $0.sessionQueue) }
        guard socketFD >= 0 else {
            throw SSHTunnelError.handshakeFailed("No TCP connection")
        }

        let handle = try await runCancellableBlocking(
            on: queue,
            work: { SessionHandle(pointer: try Self.openSession(socketFD: socketFD)) },
            discardLateResult: { libssh2_session_free($0.pointer) }
        )
        resources.withLock { $0.session = handle }
    }

    func hostKey() async throws -> (keyData: Data, keyType: String) {
        let current = try currentSession()
        return try await runCancellableBlocking(
            on: current.queue,
            work: {
                var keyLength = 0
                var keyType: Int32 = 0
                guard let keyPointer = libssh2_session_hostkey(current.handle.pointer, &keyLength, &keyType) else {
                    throw SSHTunnelError.hostKeyRejected("The server did not present a host key.")
                }
                return (Data(bytes: keyPointer, count: keyLength), HostKeyStore.keyTypeName(keyType))
            }
        )
    }

    func authenticatePassword(username: String, password: String, then secondStep: KeyboardInteractiveCredentials) async throws {
        try await authenticate(as: username, label: "Password", secondStep: secondStep) {
            try $0.password(password, then: $1)
        }
    }

    func authenticatePublicKey(
        username: String,
        keyPath: String,
        passphrase: String?,
        then secondStep: KeyboardInteractiveCredentials?
    ) async throws {
        let expandedPath = (keyPath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SSHTunnelError.authenticationFailed("Private key not found at \(keyPath)")
        }

        try await authenticate(as: username, label: "Public key", secondStep: secondStep) {
            try $0.publicKey(.readFile(at: expandedPath), passphrase: passphrase, then: $1)
        }
    }

    func authenticatePublicKeyFromMemory(
        username: String,
        keyContent: String,
        passphrase: String?,
        then secondStep: KeyboardInteractiveCredentials?
    ) async throws {
        try await authenticate(as: username, label: "In-memory key", secondStep: secondStep) {
            try $0.publicKey(.memory(keyContent), passphrase: passphrase, then: $1)
        }
    }

    func authenticateKeyboardInteractive(username: String, with credentials: KeyboardInteractiveCredentials) async throws {
        try await authenticate(as: username, label: "Keyboard-interactive", secondStep: credentials) {
            guard let answers = $1 else { return }
            try $0.keyboardInteractive(answers)
        }
    }

    func authenticateNone(username: String) async throws {
        let current = try currentSession()
        try await runCancellableBlocking(
            on: current.queue,
            work: {
                guard libssh2_userauth_list(current.handle.pointer, username, UInt32(username.utf8.count)) == nil else {
                    throw SSHTunnelError.authenticationFailed(
                        "Server requires credentials; passwordless authentication is not permitted"
                    )
                }
                guard libssh2_userauth_authenticated(current.handle.pointer) != 0 else {
                    throw SSHTunnelError.authenticationFailed("Passwordless authentication failed")
                }
            }
        )
        Self.logger.debug("Passwordless authentication successful")
    }

    func beginForwarding(destination: SSHForwardDestination) async throws -> SSHTunnel {
        let current = try currentSession()
        let (socketFD, hops) = resources.withLock { ($0.socketFD, $0.hops) }
        let bound = try Self.bindLocalSocket()

        let tunnel = SSHTunnel(
            session: current.handle.pointer,
            socketFD: socketFD,
            listenFD: bound.fd,
            localPort: bound.port,
            sessionQueue: current.queue,
            jumpHops: hops
        )

        resources.withLock { state in
            state.socketFD = -1
            state.session = nil
            state.hops = []
            state.tunnel = tunnel
        }

        tunnel.startForwarding(destination: destination)
        tunnel.startKeepAlive()
        return tunnel
    }

    // MARK: - Teardown

    func discard() {
        guard discarded.claim() else { return }

        let state = resources.withLock { current -> Resources in
            let copy = current
            current = Resources(sessionQueue: current.sessionQueue)
            return copy
        }

        if let tunnel = state.tunnel {
            tunnel.close()
            return
        }

        guard state.socketFD >= 0 || state.session != nil || !state.hops.isEmpty else { return }

        if state.socketFD >= 0 { shutdown(state.socketFD, SHUT_RDWR) }

        // Queued behind any late step, so a cancelled handshake or jump has finished first.
        state.sessionQueue.async {
            if let session = state.session?.pointer {
                libssh2_session_set_blocking(session, 1)
                tablepro_libssh2_session_disconnect(session, "Closing tunnel")
                libssh2_session_free(session)
            }
            if state.socketFD >= 0 { Darwin.close(state.socketFD) }
            guard !state.hops.isEmpty else { return }
            Task.detached { await SSHJumpChain.tearDown(state.hops) }
        }
    }

    // MARK: - Private

    private func currentSession() throws -> CurrentSession {
        let (handle, queue) = resources.withLock { ($0.session, $0.sessionQueue) }
        guard let handle else {
            throw SSHTunnelError.authenticationFailed("No active session")
        }
        return CurrentSession(handle: handle, queue: queue)
    }

    // A question the server asks waits on the user inside libssh2's callback, so a cancelled sign-in
    // also ends that wait.
    private func authenticate(
        as username: String,
        label: String,
        secondStep: KeyboardInteractiveCredentials?,
        _ attempt: @escaping @Sendable (LibSSH2Authentication, KeyboardInteractiveAnswers?) throws -> Void
    ) async throws {
        let current = try currentSession()
        let asker = secondStep?.prompter.flatMap { $0.answersChallenges ? KeyboardInteractiveAsker(prompter: $0) : nil }
        try await withTaskCancellationHandler {
            try await runCancellableBlocking(
                on: current.queue,
                work: {
                    let answers = secondStep.map { credentials in
                        KeyboardInteractiveAnswers(
                            password: credentials.password,
                            totp: credentials.totp,
                            ask: asker.map { asker in { asker.ask($0) } }
                        )
                    }
                    try attempt(LibSSH2Authentication(session: current.handle.pointer, username: username), answers)
                }
            )
        } onCancel: {
            asker?.cancel()
        }
        Self.logger.debug("\(label, privacy: .public) authentication successful for \(username, privacy: .private)")
    }

    private static func makeSessionQueue() -> DispatchQueue {
        DispatchQueue(label: "com.TablePro.ssh.session.\(UUID().uuidString)", qos: .utility)
    }

    private static func openJumpChannel(session: OpaquePointer, host: String, port: Int) throws -> OpaquePointer {
        guard let channel = LibSSH2ForwardChannel.open(
            session: session,
            destination: .tcp(host: host, port: port),
            originPort: 0
        ) else {
            let reason = LibSSH2ForwardChannel.lastErrorMessage(session: session)
            throw SSHTunnelError.channelOpenFailed("\(host):\(port): \(reason)")
        }
        // The relay reads EAGAIN as "would block", so the hop session runs non-blocking from here.
        libssh2_session_set_blocking(session, 0)
        return channel
    }

    private static func openSession(socketFD: Int32) throws -> OpaquePointer {
        guard let session = tablepro_libssh2_session_init() else {
            throw SSHTunnelError.handshakeFailed("Failed to initialize libssh2 session")
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, blockingCallTimeoutMilliseconds)

        if let failure = LibSSH2Handshake.perform(session, socket: socketFD) {
            libssh2_session_free(session)
            switch failure {
            case .negotiation(let negotiation):
                throw SSHTunnelError.negotiationFailed(negotiation, jumpHost: nil)
            case .timedOut:
                // libssh2 says "Timed out waiting on socket", which reads as blocked Local Network access,
                // but the TCP connect already succeeded.
                throw SSHTunnelError.handshakeFailed(String(localized: "The SSH server did not answer in time."))
            case .failed(let detail):
                throw SSHTunnelError.handshakeFailed(detail)
            }
        }

        return session
    }

    private static func openSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)

        guard rc == 0, let firstAddress = result else {
            let reason = rc != 0 ? String(cString: gai_strerror(rc)) : "No address found"
            throw SSHTunnelError.connectionFailed("DNS resolution failed for \(host): \(reason)")
        }
        defer { freeaddrinfo(result) }

        var lastError = "No address found"
        var candidate: UnsafeMutablePointer<addrinfo>? = firstAddress

        while let address = candidate {
            candidate = address.pointee.ai_next
            switch connectOne(address, host: host, port: port) {
            case .connected(let fd):
                return fd
            case .failed(let reason):
                lastError = reason
            }
        }

        throw SSHTunnelError.connectionFailed(lastError)
    }

    private static func connectOne(
        _ address: UnsafeMutablePointer<addrinfo>,
        host: String,
        port: Int
    ) -> ConnectAttempt {
        let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
        guard fd >= 0 else { return .failed("No socket available") }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let connectResult = Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
        if connectResult != 0, errno != EINPROGRESS {
            Darwin.close(fd)
            return .failed("Connection to \(host):\(port) failed")
        }

        if connectResult != 0, let reason = waitForConnect(fd, host: host, port: port) {
            Darwin.close(fd)
            return .failed(reason)
        }

        _ = fcntl(fd, F_SETFL, flags)
        for refusal in SSHTransportKeepAlive.enable(on: fd) {
            logger.warning("Failed to set \(refusal, privacy: .public)")
        }
        return .connected(fd)
    }

    private static func waitForConnect(_ fd: Int32, host: String, port: Int) -> String? {
        var writePollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&writePollFD, 1, connectTimeoutSeconds * 1_000) > 0 else {
            return "Connection timed out"
        }

        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
        guard socketError != 0 else { return nil }

        return "Connection to \(host):\(port) failed: \(String(cString: strerror(socketError)))"
    }

    private static func bindLocalSocket() throws -> (fd: Int32, port: Int) {
        for _ in 0 ..< portAttempts {
            let candidatePort = Int.random(in: ephemeralPorts)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var option: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &option, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(candidatePort).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindResult == 0 {
                Darwin.listen(fd, listenBacklog)
                return (fd, candidatePort)
            }

            Darwin.close(fd)
        }

        throw SSHTunnelError.noAvailablePort
    }
}
