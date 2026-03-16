//
//  LibSSH2Tunnel.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// Represents an active SSH tunnel backed by libssh2.
/// Each instance owns a TCP socket, libssh2 session, a local listening socket,
/// and the forwarding/keep-alive tasks.
internal final class LibSSH2Tunnel: @unchecked Sendable {
    let connectionId: UUID
    let localPort: Int
    let createdAt: Date

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2Tunnel")

    private let session: OpaquePointer           // LIBSSH2_SESSION*
    private let socketFD: Int32                   // TCP socket to SSH server
    private let listenFD: Int32                   // Local listening socket

    // Jump host chain (in connection order)
    private let jumpChain: [JumpHop]

    private var forwardingTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let isAlive = OSAllocatedUnfairLock(initialState: true)
    private let relayTasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())

    /// Serial queue for all libssh2 calls on this tunnel's session.
    /// libssh2 is not thread-safe per session, so every call must be serialized.
    private let sessionQueue: DispatchQueue

    /// Concurrent queue for relay I/O (poll, send, recv — no libssh2 calls).
    /// Individual libssh2 calls within each relay are dispatched to `sessionQueue`.
    private let relayQueue: DispatchQueue

    /// Dedicated queue for the accept loop (poll + accept only, no libssh2 calls).
    private let acceptQueue: DispatchQueue

    /// Callback invoked when the tunnel dies (keep-alive failure, etc.)
    var onDeath: ((UUID) -> Void)?

    struct JumpHop {
        let session: OpaquePointer    // LIBSSH2_SESSION*
        let socket: Int32             // TCP or socketpair fd
        let channel: OpaquePointer    // LIBSSH2_CHANNEL* (direct-tcpip to next hop)
        let relayTask: Task<Void, Never>?  // socketpair relay task (nil for first hop)
    }

    private static let relayBufferSize = 32_768 // 32KB

    init(connectionId: UUID, localPort: Int, session: OpaquePointer,
         socketFD: Int32, listenFD: Int32, jumpChain: [JumpHop] = []) {
        self.connectionId = connectionId
        self.localPort = localPort
        self.session = session
        self.socketFD = socketFD
        self.listenFD = listenFD
        self.jumpChain = jumpChain
        self.createdAt = Date()
        self.sessionQueue = DispatchQueue(
            label: "com.TablePro.ssh.session.\(connectionId.uuidString)",
            qos: .utility
        )
        self.relayQueue = DispatchQueue(
            label: "com.TablePro.ssh.relay.\(connectionId.uuidString)",
            qos: .utility,
            attributes: .concurrent
        )
        self.acceptQueue = DispatchQueue(
            label: "com.TablePro.ssh.accept.\(connectionId.uuidString)",
            qos: .utility
        )
    }

    var isRunning: Bool {
        isAlive.withLock { $0 }
    }

    // MARK: - Forwarding

    func startForwarding(remoteHost: String, remotePort: Int) {
        libssh2_session_set_blocking(session, 0)

        forwardingTask = Task.detached { [weak self] in
            guard let self else { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.acceptQueue.async { [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }

                    Self.logger.info(
                        "Forwarding started on port \(self.localPort) -> \(remoteHost):\(remotePort)"
                    )

                    while self.isRunning {
                        let clientFD = self.acceptClient()
                        guard clientFD >= 0 else {
                            if self.isRunning {
                                continue
                            }
                            break
                        }

                        // Open channel on sessionQueue (serialized libssh2 call),
                        // then hand off relay to relayQueue (concurrent I/O).
                        let channel: OpaquePointer? = self.sessionQueue.sync {
                            self.openDirectTcpipChannel(
                                remoteHost: remoteHost,
                                remotePort: remotePort
                            )
                        }

                        guard let channel else {
                            Self.logger.error("Failed to open direct-tcpip channel")
                            Darwin.close(clientFD)
                            continue
                        }

                        Self.logger.debug(
                            "Client connected, relaying to \(remoteHost):\(remotePort)"
                        )
                        self.spawnRelay(clientFD: clientFD, channel: channel)
                    }

                    Self.logger.info("Forwarding loop ended for port \(self.localPort)")
                }
            }
        }
    }

    // MARK: - Keep-Alive

    func startKeepAlive() {
        libssh2_keepalive_config(session, 1, 30)

        keepAliveTask = Task.detached { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && self.isRunning {
                let failed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    self.sessionQueue.async {
                        var secondsToNext: Int32 = 0
                        let rc = libssh2_keepalive_send(self.session, &secondsToNext)
                        continuation.resume(returning: rc != 0)
                    }
                }

                if failed {
                    Self.logger.warning("Keep-alive failed, marking tunnel dead")
                    self.markDead()
                    break
                }

                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        let wasAlive = isAlive.withLock { alive -> Bool in
            let was = alive
            alive = false
            return was
        }
        guard wasAlive else { return }

        // Cancel all tasks so relay loops see isCancelled
        forwardingTask?.cancel()
        keepAliveTask?.cancel()
        let currentRelayTasks = relayTasks.withLock { tasks -> [Task<Void, Never>] in
            let copy = tasks
            for task in tasks { task.cancel() }
            tasks.removeAll()
            return copy
        }

        // Shutdown socketFD to unblock any blocking reads in relay tasks
        // without closing the fd (which could be reused by another thread)
        shutdown(socketFD, SHUT_RDWR)
        // Close listenFD to stop accepting new connections
        Darwin.close(listenFD)

        // Defer session teardown to a detached task that waits for relays to exit.
        let session = self.session
        let socketFD = self.socketFD
        let jumpChain = self.jumpChain
        let connectionId = self.connectionId
        Task.detached {
            // Wait for all relay tasks to finish (they'll exit quickly since
            // socketFD is shut down and isRunning is false)
            for task in currentRelayTasks {
                await task.value
            }

            // Now safe to close the socket and tear down the session
            Darwin.close(socketFD)

            libssh2_session_set_blocking(session, 1)
            tablepro_libssh2_session_disconnect(session, "Closing tunnel")
            libssh2_session_free(session)

            for hop in jumpChain.reversed() {
                hop.relayTask?.cancel()
                libssh2_channel_free(hop.channel)
                tablepro_libssh2_session_disconnect(hop.session, "Closing")
                libssh2_session_free(hop.session)
                Darwin.close(hop.socket)
            }

            Self.logger.info("Tunnel closed for connection \(connectionId)")
        }
    }

    /// Synchronous cleanup for app termination.
    /// At termination the process is exiting imminently, so we cancel relay tasks
    /// and tear down immediately. We avoid closing socketFD or freeing the session
    /// since relay tasks may still reference them; the OS reclaims all resources.
    func closeSync() {
        let wasAlive = isAlive.withLock { alive -> Bool in
            let was = alive
            alive = false
            return was
        }
        guard wasAlive else { return }

        forwardingTask?.cancel()
        keepAliveTask?.cancel()
        relayTasks.withLock { tasks in
            for task in tasks { task.cancel() }
            tasks.removeAll()
        }

        // Shutdown sockets to unblock reads, close listenFD (accept loop only)
        shutdown(socketFD, SHUT_RDWR)
        Darwin.close(listenFD)

        // At app termination, skip session teardown and fd close.
        // Relay tasks may still be using them, and the OS reclaims everything.
        for hop in jumpChain.reversed() {
            hop.relayTask?.cancel()
        }
    }

    // MARK: - Private

    private func markDead() {
        let wasAlive = isAlive.withLock { alive -> Bool in
            let was = alive
            alive = false
            return was
        }
        if wasAlive {
            onDeath?(connectionId)
        }
    }

    /// Accept a client connection on the listening socket with a 1-second poll timeout.
    private func acceptClient() -> Int32 {
        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 1_000) // 1 second timeout

        guard pollResult > 0, pollFD.revents & Int16(POLLIN) != 0 else {
            return -1
        }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &addrLen)
            }
        }

        return clientFD
    }

    /// Open a direct-tcpip channel, handling EAGAIN with select().
    /// Must be called on `sessionQueue`.
    private func openDirectTcpipChannel(remoteHost: String, remotePort: Int) -> OpaquePointer? {
        while true {
            let channel = libssh2_channel_direct_tcpip_ex(
                session,
                remoteHost,
                Int32(remotePort),
                "127.0.0.1",
                Int32(localPort)
            )

            if let channel {
                return channel
            }

            let errno = libssh2_session_last_errno(session)
            guard errno == LIBSSH2_ERROR_EAGAIN else {
                return nil
            }

            if !waitForSocket(session: session, socketFD: socketFD, timeoutMs: 5_000) {
                return nil
            }
        }
    }

    /// Bidirectional relay between a client socket and an SSH channel.
    /// The relay loop runs on `relayQueue` (concurrent). Individual libssh2 calls
    /// are dispatched to `sessionQueue` (serial) for thread safety.
    private func spawnRelay(clientFD: Int32, channel: OpaquePointer) {
        let task = Task.detached { [weak self] in
            guard let self else {
                Darwin.close(clientFD)
                return
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.relayQueue.async { [weak self] in
                    defer { continuation.resume() }
                    guard let self else {
                        Darwin.close(clientFD)
                        return
                    }
                    self.runRelay(clientFD: clientFD, channel: channel)
                }
            }
        }

        relayTasks.withLock { tasks in
            tasks.removeAll { $0.isCancelled }
            tasks.append(task)
        }
    }

    /// Blocking relay loop. Runs on `relayQueue`; libssh2 calls go through `sessionQueue`.
    private func runRelay(clientFD: Int32, channel: OpaquePointer) {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Self.relayBufferSize)
        defer {
            buffer.deallocate()
            Darwin.close(clientFD)
            if self.isRunning {
                sessionQueue.sync {
                    libssh2_channel_close(channel)
                    libssh2_channel_free(channel)
                }
            }
        }

        while self.isRunning {
            var pollFDs = [
                pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: self.socketFD, events: Int16(POLLIN), revents: 0),
            ]

            let pollResult = poll(&pollFDs, 2, 100) // 100ms timeout
            if pollResult < 0 { break }

            // Read from SSH channel when the SSH socket has data or on timeout
            // (libssh2 may have internally buffered data)
            if pollFDs[1].revents & Int16(POLLIN) != 0 || pollResult == 0 {
                let readResult: Int = sessionQueue.sync {
                    Int(tablepro_libssh2_channel_read(channel, buffer, Self.relayBufferSize))
                }
                if readResult > 0 {
                    var totalSent = 0
                    while totalSent < readResult {
                        let sent = send(
                            clientFD,
                            buffer.advanced(by: totalSent),
                            readResult - totalSent,
                            0
                        )
                        if sent <= 0 { return }
                        totalSent += sent
                    }
                } else if readResult == 0 || sessionQueue.sync({ libssh2_channel_eof(channel) }) != 0 {
                    return
                } else if readResult != Int(LIBSSH2_ERROR_EAGAIN) {
                    return
                }
            }

            // Read from client -> write to SSH channel
            if pollFDs[0].revents & Int16(POLLIN) != 0 {
                let clientRead = recv(clientFD, buffer, Self.relayBufferSize, 0)
                if clientRead <= 0 { return }

                var totalWritten = 0
                while totalWritten < Int(clientRead) {
                    let written: Int = sessionQueue.sync {
                        Int(tablepro_libssh2_channel_write(
                            channel,
                            buffer.advanced(by: totalWritten),
                            Int(clientRead) - totalWritten
                        ))
                    }
                    if written > 0 {
                        totalWritten += written
                    } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                        _ = self.waitForSocket(
                            session: self.session,
                            socketFD: self.socketFD,
                            timeoutMs: 1_000
                        )
                    } else {
                        return
                    }
                }
            }
        }
    }

    /// Wait for the SSH socket to become ready, based on libssh2's block directions.
    private func waitForSocket(session: OpaquePointer, socketFD: Int32, timeoutMs: Int32) -> Bool {
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
