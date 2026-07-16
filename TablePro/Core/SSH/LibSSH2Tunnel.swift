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
    private let clientTasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())

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

    /// Bounds a forwarding channel open. libssh2 retries EAGAIN forever on its own, so
    /// without this a stuck open outlives the database driver's connect timeout and the
    /// client waits on a socket nothing will ever write to. Matches the driver's own
    /// connect timeout so TablePro reports the cause before the driver gives up blind.
    private static let channelOpenDeadlineSeconds: TimeInterval = 10
    private static let channelOpenPollTimeoutMs: Int32 = 5_000

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

    func startForwarding(destination: SSHForwardDestination) {
        sessionQueue.sync { libssh2_session_set_blocking(session, 0) }

        forwardingTask = Task.detached { [weak self] in
            guard let self else { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.acceptQueue.async { [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }

                    let target = destination.logDescription

                    Self.logger.info(
                        "Forwarding started on port \(self.localPort) -> \(target)"
                    )

                    while self.isRunning {
                        let clientFD = self.acceptClient()
                        guard clientFD >= 0 else {
                            if self.isRunning {
                                continue
                            }
                            break
                        }

                        self.spawnClient(clientFD: clientFD, destination: destination)
                    }

                    Self.logger.info("Forwarding loop ended for port \(self.localPort)")
                }
            }
        }
    }

    // MARK: - Keep-Alive

    func startKeepAlive() {
        sessionQueue.sync { libssh2_keepalive_config(session, 1, 30) }

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
        let currentClientTasks = clientTasks.withLock { tasks -> [Task<Void, Never>] in
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

        // Defer session teardown to a detached task that waits for all tasks to exit.
        let sessionQueue = self.sessionQueue
        let session = self.session
        let socketFD = self.socketFD
        let jumpChain = self.jumpChain
        let connectionId = self.connectionId
        let forwardingTask = self.forwardingTask
        let keepAliveTask = self.keepAliveTask
        Task.detached {
            // Wait for all tasks to exit before touching the session.
            await forwardingTask?.value
            await keepAliveTask?.value
            for task in currentClientTasks {
                await task.value
            }

            // Tear down on sessionQueue to serialize after any pending libssh2 blocks.
            sessionQueue.sync {
                Darwin.close(socketFD)
                libssh2_session_set_blocking(session, 1)
                tablepro_libssh2_session_disconnect(session, "Closing tunnel")
                libssh2_session_free(session)
            }

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
        clientTasks.withLock { tasks in
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

    /// Open the channel and relay the client, off the accept loop so a slow open cannot
    /// stall the next accept, and off `sessionQueue` between attempts so it cannot stall
    /// the relays and keep-alive that share the session.
    private func openAndRelay(clientFD: Int32, destination: SSHForwardDestination) {
        let pump = SSHForwardChannelOpenPump(
            opener: LibSSH2ForwardChannelOpener(
                session: session,
                destination: destination,
                originPort: localPort,
                sessionQueue: sessionQueue
            ),
            isActive: { [weak self] in self?.isRunning ?? false },
            deadline: Date().addingTimeInterval(Self.channelOpenDeadlineSeconds),
            pollForReadiness: { [weak self] directions in
                guard let self else { return false }
                return pollReady(
                    fd: self.socketFD,
                    directions: directions,
                    timeoutMs: Self.channelOpenPollTimeoutMs
                )
            }
        )

        let outcome = pump.run()
        logChannelOpenOutcome(outcome, destination: destination)
        handleChannelOpenOutcome(outcome, clientFD: clientFD) { channel in
            runRelay(clientFD: clientFD, channel: channel)
        }
    }

    private func logChannelOpenOutcome(_ outcome: ChannelOpenOutcome, destination: SSHForwardDestination) {
        let target = destination.logDescription
        switch outcome {
        case .opened:
            Self.logger.debug("Client connected, relaying to \(target)")
        case .failed(let errorCode):
            Self.logger.error("Forwarding channel to \(target) failed to open, libssh2 error \(errorCode)")
        case .timedOut:
            Self.logger.error(
                "Forwarding channel to \(target) did not open within \(Int(Self.channelOpenDeadlineSeconds))s, closing local socket"
            )
        case .cancelled:
            break
        }
    }

    /// Opens the channel and relays one accepted client, off the accept loop so a slow
    /// open cannot delay the next accept. The loop runs on `relayQueue` (concurrent);
    /// individual libssh2 calls are dispatched to `sessionQueue` (serial) for thread safety.
    private func spawnClient(clientFD: Int32, destination: SSHForwardDestination) {
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
                    self.openAndRelay(clientFD: clientFD, destination: destination)
                }
            }
        }

        let shouldCancel = clientTasks.withLock { tasks -> Bool in
            tasks.removeAll { $0.isCancelled }
            tasks.append(task)
            return !isAlive.withLock { $0 }
        }
        if shouldCancel {
            task.cancel()
        }
    }

    /// Blocking relay loop. Runs on `relayQueue`; libssh2 calls go through `sessionQueue`.
    private func runRelay(clientFD: Int32, channel: OpaquePointer) {
        let relay = SSHChannelRelay(
            localFD: clientFD,
            transportFD: socketFD,
            channelIO: LibSSH2ChannelIO(channel: channel, session: session, sessionQueue: sessionQueue),
            bufferSize: Self.relayBufferSize,
            isActive: { [weak self] in self?.isRunning ?? false }
        )

        let termination = relay.run()

        Darwin.close(clientFD)
        guard self.isRunning else { return }

        sessionQueue.sync {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
        }

        if termination == .transportHangup {
            Self.logger.info("SSH transport hung up, marking tunnel dead for \(self.connectionId)")
            markDead()
        }
    }
}
