//
//  RemoteSQLiteTunnel.swift
//  TablePro
//

import CLibSSH2
import Foundation
import os

/// A loopback listener whose accepted clients each get a fresh exec channel running the SQLite
/// agent on the SSH server, so the SQLite plugin can reach a live database on that server as if it
/// were a local port.
///
/// It mirrors `LibSSH2Tunnel`, which forwards a TCP port over one authenticated session: the same
/// accept loop, keepalive, teardown latch and byte counter. What differs is the cargo. A forwarding
/// tunnel opens a direct-tcpip channel per client; this opens a session channel and runs a command
/// on it, and it admits a client only after the client presents the per-connection token, because
/// nothing behind this listener authenticates the way a database port does.
final class RemoteSQLiteTunnel: @unchecked Sendable {
    let connectionId: UUID
    let localPort: Int
    let createdAt: Date

    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteSQLiteTunnel")

    private let chain: LibSSH2TunnelFactory.AuthenticatedChain
    private let listenFD: Int32
    private let command: String
    private let token: String

    private var session: OpaquePointer { chain.session }
    private var socketFD: Int32 { chain.socketFD }

    private var forwardingTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let aliveLatch = TeardownLatch()
    private let clientTasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())

    private let sessionQueue: DispatchQueue
    private let relayQueue: DispatchQueue
    private let acceptQueue: DispatchQueue

    var onDeath: ((UUID) -> Void)?

    private let byteCounter = TransportByteCounter()

    private static let relayBufferSize = 32_768
    private static let channelOpenDeadlineSeconds: TimeInterval = 6
    private static let channelOpenPollTimeoutMs: Int32 = 5_000
    private static let acceptPollTimeoutMs: Int32 = 200
    private static let admissionTimeoutSeconds = 5

    init(
        connectionId: UUID,
        localPort: Int,
        chain: LibSSH2TunnelFactory.AuthenticatedChain,
        listenFD: Int32,
        command: String,
        token: String
    ) {
        self.connectionId = connectionId
        self.localPort = localPort
        self.chain = chain
        self.listenFD = listenFD
        self.command = command
        self.token = token
        self.createdAt = Date()
        self.sessionQueue = DispatchQueue(label: "com.TablePro.rsqlite.session.\(connectionId.uuidString)", qos: .utility)
        self.relayQueue = DispatchQueue(
            label: "com.TablePro.rsqlite.relay.\(connectionId.uuidString)", qos: .utility, attributes: .concurrent
        )
        self.acceptQueue = DispatchQueue(label: "com.TablePro.rsqlite.accept.\(connectionId.uuidString)", qos: .utility)
        TransportActivityRegistry.shared.register(byteCounter, for: connectionId)
    }

    var isRunning: Bool { aliveLatch.isLive }

    // MARK: - Forwarding

    func startForwarding() {
        sessionQueue.sync { libssh2_session_set_blocking(session, 0) }

        forwardingTask = Task.detached { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.acceptQueue.async { [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }
                    Self.logger.info("Remote SQLite listener started on 127.0.0.1:\(self.localPort)")
                    while self.isRunning {
                        guard let clientFD = self.acceptClient() else {
                            if self.isRunning { continue }
                            break
                        }
                        self.spawnClient(clientFD: clientFD)
                    }
                }
            }
        }
    }

    func startKeepAlive() {
        sessionQueue.sync { libssh2_keepalive_config(session, 1, 30) }
        keepAliveTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRunning {
                let failed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    self.sessionQueue.async {
                        var secondsToNext: Int32 = 0
                        let rc = libssh2_keepalive_send(self.session, &secondsToNext)
                        continuation.resume(returning: sshKeepAliveDidFail(rc))
                    }
                }
                if failed {
                    Self.logger.warning("Remote SQLite keepalive failed, marking dead")
                    self.markDead()
                    break
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        guard aliveLatch.claim() else { return }
        performTeardown()
    }

    func closeSync() {
        guard aliveLatch.claim() else { return }
        forwardingTask?.cancel()
        keepAliveTask?.cancel()
        clientTasks.withLock { tasks in
            for task in tasks { task.cancel() }
            tasks.removeAll()
        }
        shutdown(socketFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    private func markDead() {
        guard aliveLatch.claim() else { return }
        performTeardown()
        onDeath?(connectionId)
    }

    private func performTeardown() {
        forwardingTask?.cancel()
        keepAliveTask?.cancel()
        let currentClientTasks = clientTasks.withLock { tasks -> [Task<Void, Never>] in
            let copy = tasks
            for task in tasks { task.cancel() }
            tasks.removeAll()
            return copy
        }

        shutdown(socketFD, SHUT_RDWR)
        Darwin.close(listenFD)

        let chain = self.chain
        let forwardingTask = self.forwardingTask
        let keepAliveTask = self.keepAliveTask
        let connectionId = self.connectionId
        Task.detached {
            await forwardingTask?.value
            await keepAliveTask?.value
            for task in currentClientTasks { await task.value }
            LibSSH2TunnelFactory.cleanupChain(chain, reason: "Closing remote SQLite session")
            Self.logger.info("Remote SQLite session closed for \(connectionId)")
        }
    }

    // MARK: - Accept

    private func acceptClient() -> Int32? {
        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, Self.acceptPollTimeoutMs) > 0, pollFD.revents & Int16(POLLIN) != 0 else {
            return nil
        }
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &addrLen) }
        }
        return clientFD >= 0 ? clientFD : nil
    }

    private func spawnClient(clientFD: Int32) {
        let task = Task.detached { [weak self] in
            guard let self else { Darwin.close(clientFD); return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.relayQueue.async { [weak self] in
                    defer { continuation.resume() }
                    guard let self else { Darwin.close(clientFD); return }
                    self.admitAndRelay(clientFD: clientFD)
                }
            }
        }
        let shouldCancel = clientTasks.withLock { tasks -> Bool in
            tasks.removeAll { $0.isCancelled }
            tasks.append(task)
            return !aliveLatch.isLive
        }
        if shouldCancel { task.cancel() }
    }

    private func admitAndRelay(clientFD: Int32) {
        guard let line = Self.readAdmissionLine(clientFD),
              RemoteSQLiteAdmission.isAuthorized(line: line, token: token) else {
            Self.logger.warning("Remote SQLite client rejected: bad or missing token")
            Darwin.close(clientFD)
            return
        }

        let opener = RemoteSQLiteExecChannelOpener(session: session, command: command, sessionQueue: sessionQueue)
        let pump = SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { [weak self] in self?.isRunning ?? false },
            deadline: Date().addingTimeInterval(Self.channelOpenDeadlineSeconds),
            pollForReadiness: { [weak self] directions in
                guard let self else { return false }
                return pollReady(fd: self.socketFD, directions: directions, timeoutMs: Self.channelOpenPollTimeoutMs)
            }
        )

        switch pump.run() {
        case .opened(let channel):
            runRelay(clientFD: clientFD, channel: channel)
        case .failed(let code, let message):
            Self.logger.error("Remote SQLite exec channel failed to open, libssh2 \(code): \(message)")
            Darwin.close(clientFD)
        case .timedOut, .cancelled:
            /// The channel may have opened before the deadline and be waiting on the exec request.
            /// The pump never took ownership, so free it here rather than leak it on the live session.
            opener.abort()
            Darwin.close(clientFD)
        }
    }

    /// Reads the token line the client sends before any protocol frame. One byte at a time up to the
    /// newline, so the first protocol bytes that follow it stay in the socket for the relay, with a
    /// receive timeout and a length cap so a silent or hostile client cannot hold the slot open.
    private static func readAdmissionLine(_ clientFD: Int32) -> Data? {
        var timeout = timeval(tv_sec: admissionTimeoutSeconds, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var clear = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &clear, socklen_t(MemoryLayout<timeval>.size))
        }

        var line = Data()
        var byte: UInt8 = 0
        while line.count <= RemoteSQLiteAdmission.maxLineLength {
            let read = recv(clientFD, &byte, 1, 0)
            if read <= 0 { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }

    private func runRelay(clientFD: Int32, channel: OpaquePointer) {
        let relay = SSHChannelRelay(
            localFD: clientFD,
            transportFD: socketFD,
            channelIO: LibSSH2ChannelIO(channel: channel, session: session, sessionQueue: sessionQueue),
            bufferSize: Self.relayBufferSize,
            isActive: { [weak self] in self?.isRunning ?? false },
            byteCounter: byteCounter
        )

        let termination = relay.run()
        Darwin.close(clientFD)

        guard isRunning else { return }

        /// Send EOF so the agent sees its standard input close and exits, then free without the
        /// blocking `libssh2_channel_close`, which waits for the remote child to exit and would
        /// stall every other call on this session's serial queue. The agent's own idle watchdog
        /// reaps it if EOF is somehow missed.
        sessionQueue.sync {
            _ = libssh2_channel_send_eof(channel)
            libssh2_channel_free(channel)
        }

        if termination == .transportHangup {
            Self.logger.info("Remote SQLite transport hung up for \(self.connectionId)")
            markDead()
        }
    }
}
