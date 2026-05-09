import Foundation
import CLibSSH2
import os

final class AliveFlag: Sendable {
    private let _lock = NSLock()
    private nonisolated(unsafe) var _value = true

    nonisolated init() {}

    nonisolated var value: Bool {
        get { _lock.lock(); defer { _lock.unlock() }; return _value }
        set { _lock.lock(); _value = newValue; _lock.unlock() }
    }
}

actor SSHTunnel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnel")

    private var session: OpaquePointer?
    private var socketFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var localPort: Int = 0
    nonisolated let aliveFlag = AliveFlag()
    private var relayTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private static let bufferSize = 32_768
    private static let connectionTimeout: Int32 = 10
    nonisolated let sessionLock = NSLock()

    private var isAlive: Bool {
        get { aliveFlag.value }
        set { aliveFlag.value = newValue }
    }

    var port: Int { localPort }

    // MARK: - TCP Connection

    func connect(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let rc = getaddrinfo(host, portString, &hints, &result)

        guard rc == 0, let firstAddr = result else {
            let errorMsg = rc != 0 ? String(cString: gai_strerror(rc)) : "No address found"
            throw SSHTunnelError.connectionFailed("DNS resolution failed for \(host): \(errorMsg)")
        }
        defer { freeaddrinfo(result) }

        var currentAddr: UnsafeMutablePointer<addrinfo>? = firstAddr
        var lastError = "No address found"

        while let addrInfo = currentAddr {
            let fd = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
            guard fd >= 0 else {
                currentAddr = addrInfo.pointee.ai_next
                continue
            }

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let connectResult = Darwin.connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)

            if connectResult != 0 && errno != EINPROGRESS {
                Darwin.close(fd)
                lastError = "Connection to \(host):\(port) failed"
                currentAddr = addrInfo.pointee.ai_next
                continue
            }

            if connectResult != 0 {
                var writePollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&writePollFD, 1, Self.connectionTimeout * 1_000)

                if pollResult <= 0 {
                    Darwin.close(fd)
                    lastError = "Connection timed out"
                    currentAddr = addrInfo.pointee.ai_next
                    continue
                }

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

            _ = fcntl(fd, F_SETFL, flags)

            socketFD = fd
            Self.logger.debug("TCP connected to \(host):\(port)")
            return
        }

        throw SSHTunnelError.connectionFailed(lastError)
    }

    // MARK: - SSH Handshake

    func handshake() throws {
        guard socketFD >= 0 else {
            throw SSHTunnelError.handshakeFailed("No TCP connection")
        }

        guard let sess = tablepro_libssh2_session_init() else {
            throw SSHTunnelError.handshakeFailed("Failed to initialize libssh2 session")
        }

        libssh2_session_set_blocking(sess, 1)

        let rc = libssh2_session_handshake(sess, socketFD)
        if rc != 0 {
            libssh2_session_free(sess)
            throw SSHTunnelError.handshakeFailed("Handshake failed (error \(rc))")
        }

        session = sess
    }

    // MARK: - Authentication

    func authenticatePassword(username: String, password: String) throws {
        guard let session else {
            throw SSHTunnelError.authenticationFailed("No active session")
        }

        let rc = libssh2_userauth_password_ex(
            session,
            username,
            UInt32(username.utf8.count),
            password,
            UInt32(password.utf8.count),
            nil
        )

        if rc != 0 {
            throw SSHTunnelError.authenticationFailed("Password authentication failed (error \(rc))")
        }

        Self.logger.debug("Password authentication successful for \(username)")
    }

    func authenticatePublicKey(username: String, keyPath: String, passphrase: String?) throws {
        guard let session else {
            throw SSHTunnelError.authenticationFailed("No active session")
        }

        let expandedPath = (keyPath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SSHTunnelError.authenticationFailed("Private key not found at \(keyPath)")
        }

        let pubKeyPath = expandedPath + ".pub"
        let pubKeyPathOrNil: String? = FileManager.default.fileExists(atPath: pubKeyPath) ? pubKeyPath : nil

        let rc = libssh2_userauth_publickey_fromfile_ex(
            session,
            username,
            UInt32(username.utf8.count),
            pubKeyPathOrNil,
            expandedPath,
            passphrase
        )

        if rc != 0 {
            throw SSHTunnelError.authenticationFailed("Public key authentication failed (error \(rc))")
        }

        Self.logger.debug("Public key authentication successful for \(username)")
    }

    func authenticatePublicKeyFromMemory(username: String, keyContent: String, passphrase: String?) throws {
        guard let session else {
            throw SSHTunnelError.authenticationFailed("No active session")
        }

        let rc = keyContent.withCString { keyPtr in
            libssh2_userauth_publickey_frommemory(
                session,
                username,
                username.utf8.count,
                nil, 0,
                keyPtr, keyContent.utf8.count,
                passphrase
            )
        }

        if rc != 0 {
            throw SSHTunnelError.authenticationFailed("In-memory key authentication failed (error \(rc))")
        }

        Self.logger.debug("In-memory key authentication successful for \(username)")
    }

    // MARK: - Port Forwarding

    func startForwarding(remoteHost: String, remotePort: Int) throws {
        let bound = try bindLocalSocket()
        listenFD = bound.fd
        localPort = bound.port

        libssh2_session_set_blocking(session, 0)

        Self.logger.info("Forwarding 127.0.0.1:\(self.localPort) -> \(remoteHost):\(remotePort)")

        relayTask = Task.detached { [weak self] in
            guard let self else { return }

            while await self.isAlive {
                let clientFD = await self.acceptClient()
                guard clientFD >= 0 else { continue }

                let channel = await self.openDirectTcpipChannel(
                    remoteHost: remoteHost,
                    remotePort: remotePort
                )

                guard let channel else {
                    Self.logger.error("Failed to open direct-tcpip channel")
                    Darwin.close(clientFD)
                    continue
                }

                Self.logger.debug("Client connected, relaying to \(remoteHost):\(remotePort)")

                let sshFD = await self.socketFD
                let flag = self.aliveFlag
                let lock = self.sessionLock
                nonisolated(unsafe) let unsafeChannel = channel
                Thread.detachNewThread {
                    SSHTunnel.relayStatic(
                        clientFD: clientFD, channel: unsafeChannel, sshFD: sshFD,
                        aliveFlag: flag, lock: lock
                    )
                }
            }

            Self.logger.info("Forwarding loop ended")
        }
    }

    // MARK: - Keep-Alive

    func startKeepAlive() {
        guard let session else { return }

        libssh2_keepalive_config(session, 1, 30)

        keepAliveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let failed = await self.sendKeepAlive()
                if failed {
                    Self.logger.warning("Keep-alive failed, marking tunnel dead")
                    await self.markDead()
                    break
                }

                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        guard isAlive else { return }
        isAlive = false

        relayTask?.cancel()
        keepAliveTask?.cancel()

        // Close listen socket first — stops accept loop
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }

        // Shutdown SSH socket — breaks relay poll() immediately
        if socketFD >= 0 {
            shutdown(socketFD, SHUT_RDWR)
            Darwin.close(socketFD)
            socketFD = -1
        }

        // Free session off-actor to avoid blocking the actor (libssh2_session_disconnect
        // can take seconds on a slow network). The detached thread acquires sessionLock
        // first, which serializes with the relay thread's libssh2 calls — the relay
        // will see isAlive == false after its current locked operation and exit.
        let sess = session
        session = nil
        let lock = sessionLock
        if let sess {
            nonisolated(unsafe) let unsafeSess = sess
            Thread.detachNewThread {
                lock.lock()
                libssh2_session_set_blocking(unsafeSess, 1)
                tablepro_libssh2_session_disconnect(unsafeSess, "Closing tunnel")
                libssh2_session_free(unsafeSess)
                lock.unlock()
            }
        }

        Self.logger.info("Tunnel closed (local port \(self.localPort))")
    }

    // MARK: - Private Helpers

    private func markDead() {
        close()
    }

    private func sendKeepAlive() -> Bool {
        guard let session else { return true }
        sessionLock.lock()
        var secondsToNext: Int32 = 0
        let rc = libssh2_keepalive_send(session, &secondsToNext)
        sessionLock.unlock()
        return rc != 0
    }

    private func bindLocalSocket() throws -> (fd: Int32, port: Int) {
        for _ in 0..<20 {
            let candidatePort = Int.random(in: 49152...65535)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var opt: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(candidatePort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindResult == 0 {
                Darwin.listen(fd, 5)
                return (fd, candidatePort)
            }

            Darwin.close(fd)
        }

        throw SSHTunnelError.noAvailablePort
    }

    private func acceptClient() -> Int32 {
        guard listenFD >= 0 else { return -1 }

        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 1_000)

        guard pollResult > 0, pollFD.revents & Int16(POLLIN) != 0 else {
            return -1
        }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        return withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &addrLen)
            }
        }
    }

    private func openDirectTcpipChannel(remoteHost: String, remotePort: Int) -> OpaquePointer? {
        for _ in 0..<30 {
            guard isAlive, let session else { return nil }

            sessionLock.lock()
            let channel = libssh2_channel_direct_tcpip_ex(
                session,
                remoteHost,
                Int32(remotePort),
                "127.0.0.1",
                Int32(localPort)
            )
            let errNo = libssh2_session_last_errno(session)
            sessionLock.unlock()

            if let channel {
                return channel
            }

            guard errNo == LIBSSH2_ERROR_EAGAIN else {
                return nil
            }

            if !waitForSocket(timeoutMs: 5_000) {
                return nil
            }
        }
        return nil
    }

    // Relay runs outside the actor on a detached thread.
    // Uses NSLock to serialize libssh2 calls (libssh2 is not thread-safe per-session).
    // This prevents blocking the actor, which other code (PQexec, keepalive) needs.
    private static func relayStatic(
        clientFD: Int32, channel: OpaquePointer, sshFD: Int32,
        aliveFlag: AliveFlag, lock: NSLock
    ) {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
            Darwin.close(clientFD)
            lock.lock()
            if aliveFlag.value {
                libssh2_channel_close(channel)
                libssh2_channel_free(channel)
            }
            lock.unlock()
        }

        while aliveFlag.value {
            var pollFDs = [
                pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: sshFD, events: Int16(POLLIN), revents: 0),
            ]

            let pollResult = poll(&pollFDs, 2, 500)
            if pollResult < 0 { break }

            // Channel -> Client
            if pollFDs[1].revents & Int16(POLLIN) != 0 {
                lock.lock()
                guard aliveFlag.value else { lock.unlock(); return }
                let readResult = Int(tablepro_libssh2_channel_read(channel, buffer, bufferSize))
                let eof = libssh2_channel_eof(channel)
                lock.unlock()

                if readResult > 0 {
                    var totalSent = 0
                    while totalSent < readResult {
                        let sent = send(clientFD, buffer.advanced(by: totalSent), readResult - totalSent, 0)
                        if sent <= 0 { return }
                        totalSent += sent
                    }
                } else if readResult == 0 || eof != 0 {
                    return
                } else if readResult != Int(LIBSSH2_ERROR_EAGAIN) {
                    return
                }
            }

            // Client -> Channel
            if pollFDs[0].revents & Int16(POLLIN) != 0 {
                let clientRead = recv(clientFD, buffer, bufferSize, 0)
                if clientRead <= 0 { return }

                var totalWritten = 0
                while totalWritten < Int(clientRead) {
                    lock.lock()
                    guard aliveFlag.value else { lock.unlock(); return }
                    let written = Int(tablepro_libssh2_channel_write(
                        channel,
                        buffer.advanced(by: totalWritten),
                        Int(clientRead) - totalWritten
                    ))
                    lock.unlock()

                    if written > 0 {
                        totalWritten += written
                    } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                        usleep(10_000)
                    } else {
                        return
                    }
                }
            }
        }
    }

    private func waitForSocket(timeoutMs: Int32) -> Bool {
        guard let session else { return false }

        let directions = libssh2_session_block_directions(session)

        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            events |= Int16(POLLIN)
        }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            events |= Int16(POLLOUT)
        }

        guard events != 0 else { return true }

        var pollFD = pollfd(fd: socketFD, events: events, revents: 0)
        let rc = poll(&pollFD, 1, timeoutMs)
        return rc > 0
    }
}
