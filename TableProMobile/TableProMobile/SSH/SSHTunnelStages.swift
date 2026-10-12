import CLibSSH2
import Foundation
import os
import TableProCoreTypes
import TableProSSHTransport

/// The steps `SSHTunnelFactory` walks to turn a configuration into a forwarding tunnel, named as a
/// protocol so the factory's hand-over guarantee can be tested without an SSH server: a spy that
/// throws at step N asserts the factory released what it had built.
nonisolated protocol SSHTunnelStages: Sendable {
    associatedtype Tunnel: Sendable

    func connect(host: String, port: Int) async throws
    func handshake() async throws
    func hostKey() async throws -> (keyData: Data, keyType: String)
    func authenticatePassword(username: String, password: String) async throws
    func authenticatePublicKey(username: String, keyPath: String, passphrase: String?) async throws
    func authenticatePublicKeyFromMemory(username: String, keyContent: String, passphrase: String?) async throws
    func authenticateNone(username: String) async throws
    func beginForwarding(destination: SSHForwardDestination) async throws -> Tunnel

    /// Releases whatever has been built so far, once. Safe to call at any step, including after
    /// `beginForwarding`, where it closes the tunnel that took the resources over.
    func discard()
}

/// Builds a libssh2 session against an SSH server, one cancellable blocking step at a time.
///
/// Every step runs on `sessionQueue` through `runCancellableBlocking`, so a cancelled connect
/// returns to the caller at once while the blocking C call finishes on its own thread. The losing
/// attempt never adopts what it produced: `discardLateResult` closes the socket it connected and
/// frees the session it opened, which is what "cancelling a connect does not stop the driver"
/// requires. `libssh2_session_handshake` blocks for its full timeout whatever `Task.cancel()` does.
///
/// The same queue is handed to the tunnel at the end, so a late connect step and the tunnel's own
/// libssh2 calls can never run at once.
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

    private enum ConnectAttempt {
        case connected(Int32)
        case failed(String)
    }

    /// What this builder still owes a release. The listening socket is absent on purpose: nothing
    /// between binding it and handing it to the tunnel can throw, so it is never this type's to
    /// release.
    private struct Resources {
        var socketFD: Int32 = -1
        var session: SessionHandle?
        var tunnel: SSHTunnel?
    }

    private let sessionQueue: DispatchQueue
    private let resources = OSAllocatedUnfairLock(initialState: Resources())
    private let discarded = TeardownLatch()

    init() {
        sessionQueue = DispatchQueue(
            label: "com.TablePro.ssh.session.\(UUID().uuidString)",
            qos: .utility
        )
    }

    // MARK: - Steps

    func connect(host: String, port: Int) async throws {
        let fd = try await runCancellableBlocking(
            on: sessionQueue,
            work: { try Self.openSocket(host: host, port: port) },
            discardLateResult: { Darwin.close($0) }
        )
        resources.withLock { $0.socketFD = fd }
        Self.logger.debug("TCP connected to \(host, privacy: .private):\(port)")
    }

    func handshake() async throws {
        let socketFD = resources.withLock { $0.socketFD }
        guard socketFD >= 0 else {
            throw SSHTunnelError.handshakeFailed("No TCP connection")
        }

        let handle = try await runCancellableBlocking(
            on: sessionQueue,
            work: { SessionHandle(pointer: try Self.openSession(socketFD: socketFD)) },
            discardLateResult: { libssh2_session_free($0.pointer) }
        )
        resources.withLock { $0.session = handle }
    }

    func hostKey() async throws -> (keyData: Data, keyType: String) {
        let handle = try currentSession()
        return try await runCancellableBlocking(
            on: sessionQueue,
            work: {
                var keyLength = 0
                var keyType: Int32 = 0
                guard let keyPointer = libssh2_session_hostkey(handle.pointer, &keyLength, &keyType) else {
                    throw SSHTunnelError.hostKeyRejected("The server did not present a host key.")
                }
                return (Data(bytes: keyPointer, count: keyLength), HostKeyStore.keyTypeName(keyType))
            }
        )
    }

    func authenticatePassword(username: String, password: String) async throws {
        let handle = try currentSession()
        try await authenticate(as: username, label: "Password") {
            libssh2_userauth_password_ex(
                handle.pointer,
                username,
                UInt32(username.utf8.count),
                password,
                UInt32(password.utf8.count),
                nil
            )
        }
    }

    func authenticatePublicKey(username: String, keyPath: String, passphrase: String?) async throws {
        let handle = try currentSession()
        let expandedPath = (keyPath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SSHTunnelError.authenticationFailed("Private key not found at \(keyPath)")
        }

        let publicKeyPath = expandedPath + ".pub"
        let publicKeyPathOrNil: String? = FileManager.default.fileExists(atPath: publicKeyPath) ? publicKeyPath : nil

        try await authenticate(as: username, label: "Public key") {
            libssh2_userauth_publickey_fromfile_ex(
                handle.pointer,
                username,
                UInt32(username.utf8.count),
                publicKeyPathOrNil,
                expandedPath,
                passphrase
            )
        }
    }

    func authenticatePublicKeyFromMemory(username: String, keyContent: String, passphrase: String?) async throws {
        let handle = try currentSession()
        try await authenticate(as: username, label: "In-memory key") {
            keyContent.withCString { keyPointer in
                libssh2_userauth_publickey_frommemory(
                    handle.pointer,
                    username,
                    username.utf8.count,
                    nil, 0,
                    keyPointer, keyContent.utf8.count,
                    passphrase
                )
            }
        }
    }

    func authenticateNone(username: String) async throws {
        let handle = try currentSession()
        try await runCancellableBlocking(
            on: sessionQueue,
            work: {
                guard libssh2_userauth_list(handle.pointer, username, UInt32(username.utf8.count)) == nil else {
                    throw SSHTunnelError.authenticationFailed(
                        "Server requires credentials; passwordless authentication is not permitted"
                    )
                }
                guard libssh2_userauth_authenticated(handle.pointer) != 0 else {
                    throw SSHTunnelError.authenticationFailed("Passwordless authentication failed")
                }
            }
        )
        Self.logger.debug("Passwordless authentication successful")
    }

    func beginForwarding(destination: SSHForwardDestination) async throws -> SSHTunnel {
        let handle = try currentSession()
        let socketFD = resources.withLock { $0.socketFD }
        let bound = try Self.bindLocalSocket()

        let tunnel = SSHTunnel(
            session: handle.pointer,
            socketFD: socketFD,
            listenFD: bound.fd,
            localPort: bound.port,
            sessionQueue: sessionQueue
        )

        resources.withLock { state in
            state.socketFD = -1
            state.session = nil
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
            current = Resources()
            return copy
        }

        if let tunnel = state.tunnel {
            tunnel.close()
            return
        }

        guard state.socketFD >= 0 || state.session != nil else { return }

        if state.socketFD >= 0 { shutdown(state.socketFD, SHUT_RDWR) }

        sessionQueue.async {
            if let session = state.session?.pointer {
                libssh2_session_set_blocking(session, 1)
                tablepro_libssh2_session_disconnect(session, "Closing tunnel")
                libssh2_session_free(session)
            }
            if state.socketFD >= 0 { Darwin.close(state.socketFD) }
        }
    }

    // MARK: - Private

    private func currentSession() throws -> SessionHandle {
        guard let handle = resources.withLock({ $0.session }) else {
            throw SSHTunnelError.authenticationFailed("No active session")
        }
        return handle
    }

    private func authenticate(
        as username: String,
        label: String,
        _ attempt: @escaping @Sendable () -> Int32
    ) async throws {
        try await runCancellableBlocking(
            on: sessionQueue,
            work: {
                let rc = attempt()
                guard rc == 0 else {
                    throw SSHTunnelError.authenticationFailed("\(label) authentication failed (error \(rc))")
                }
            }
        )
        Self.logger.debug("\(label, privacy: .public) authentication successful for \(username, privacy: .private)")
    }

    private static func openSession(socketFD: Int32) throws -> OpaquePointer {
        guard let session = tablepro_libssh2_session_init() else {
            throw SSHTunnelError.handshakeFailed("Failed to initialize libssh2 session")
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, blockingCallTimeoutMilliseconds)

        let rc = libssh2_session_handshake(session, socketFD)
        guard rc == 0 else {
            libssh2_session_free(session)
            throw SSHTunnelError.handshakeFailed("Handshake failed (error \(rc))")
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
