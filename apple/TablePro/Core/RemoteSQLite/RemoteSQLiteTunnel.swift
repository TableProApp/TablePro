//
//  RemoteSQLiteTunnel.swift
//  TablePro
//

import CLibSSH2
import Foundation
import os

import TableProSSHTransport

// A loopback listener whose accepted clients each get a fresh exec channel running the SQLite agent
// on the SSH server, so the SQLite plugin can reach a live database there as if it were a local port.
//
// It mirrors `LibSSH2Tunnel`: the same acceptor, keepalive, teardown latch and byte counter. What
// differs is the cargo. A forwarding tunnel opens a direct-tcpip channel per client; this opens a
// session channel and runs a command on it, and it admits a client only after the client presents the
// per-connection token, because nothing behind this listener authenticates the way a database port does.
final class RemoteSQLiteTunnel: @unchecked Sendable {
    let connectionId: UUID
    let localPort: Int
    let createdAt: Date

    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteSQLiteTunnel")

    private let chain: LibSSH2TunnelFactory.AuthenticatedChain
    private let listenFD: Int32
    private let command: String
    private let token: String
    private let relayDeadlines: ConnectionRelayDeadlineProvider
    private let connectionTimeoutFailure = OSAllocatedUnfairLock<ConnectionTimeoutError?>(initialState: nil)

    private var session: OpaquePointer { chain.session }
    private var socketFD: Int32 { chain.socketFD }

    private var acceptor: SSHListenerAcceptor?
    private var keepAliveTask: Task<Void, Never>?
    private let aliveLatch = TeardownLatch()

    // Each accepted client from accept until its channel is freed or given up, so teardown frees the
    // session only once none of them can touch it.
    private let clientRelays = DispatchGroup()

    private let pump: SSHSessionPump
    private let relayQueue: DispatchQueue
    private let acceptQueue: DispatchQueue

    var onDeath: ((UUID) -> Void)?

    private let byteCounter = TransportByteCounter()

    private static let relayBufferSize = 32_768

    private struct ChannelHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }
    private static let admissionTimeoutSeconds = 5

    init(
        connectionId: UUID,
        localPort: Int,
        chain: LibSSH2TunnelFactory.AuthenticatedChain,
        listenFD: Int32,
        command: String,
        token: String,
        connectionDeadline: ConnectionDeadline
    ) {
        self.connectionId = connectionId
        self.localPort = localPort
        self.chain = chain
        self.listenFD = listenFD
        self.command = command
        self.token = token
        self.relayDeadlines = ConnectionRelayDeadlineProvider(initialDeadline: connectionDeadline)
        self.createdAt = Date()
        self.pump = SSHSessionPump(
            transportFD: chain.socketFD,
            queue: DispatchQueue(label: "com.TablePro.rsqlite.session.\(connectionId.uuidString)", qos: .utility)
        )
        self.relayQueue = DispatchQueue(
            label: "com.TablePro.rsqlite.relay.\(connectionId.uuidString)", qos: .utility, attributes: .concurrent
        )
        self.acceptQueue = DispatchQueue(label: "com.TablePro.rsqlite.accept.\(connectionId.uuidString)", qos: .utility)
        TransportActivityRegistry.shared.register(byteCounter, for: connectionId)
    }

    var isRunning: Bool { aliveLatch.isLive }

    func consumeLastConnectionFailure() -> ConnectionTimeoutError? {
        connectionTimeoutFailure.withLock { failure in
            defer { failure = nil }
            return failure
        }
    }

    // MARK: - Forwarding

    func startForwarding() {
        pump.perform { libssh2_session_set_blocking(session, 0) }

        // A handler already running when the latch is claimed may still spawn one relay; teardown
        // waits for the cancel handler before the relay group, so it waits for that relay too.
        let acceptor = SSHListenerAcceptor(listenFD: listenFD, queue: acceptQueue) { [weak self] client in
            guard let self, self.isRunning else {
                Darwin.close(client.descriptor)
                return
            }
            self.spawnClient(clientFD: client.descriptor, budget: self.relayDeadlines.next())
        }
        self.acceptor = acceptor
        acceptor.start()
        Self.logger.info("Remote SQLite listener started on 127.0.0.1:\(self.localPort)")
    }

    func startKeepAlive() {
        pump.perform { LibSSH2KeepAlive.configure(session: session) }
        keepAliveTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRunning {
                let outcome = await self.pump.performAsync {
                    LibSSH2KeepAlive.send(session: self.session, transportFD: self.socketFD)
                }
                if outcome.failed {
                    Self.logger.warning("Remote SQLite keepalive failed, marking dead")
                    self.markDead()
                    break
                }
                try? await Task.sleep(for: .seconds(outcome.secondsToNext))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        guard aliveLatch.claim() else { return }
        performTeardown()
    }

    // App termination: waits for nothing, closes no descriptor and frees no session, since a relay or
    // the accept handler may still be using them and the OS reclaims them all.
    func closeSync() {
        guard aliveLatch.claim() else { return }
        acceptor?.cancel()
        keepAliveTask?.cancel()
        pump.stop()
        shutdown(socketFD, SHUT_RDWR)
    }

    private func markDead() {
        guard aliveLatch.claim() else { return }
        performTeardown()
        onDeath?(connectionId)
    }

    // `shutdown` wakes every open or free waiting on the transport but keeps the descriptor number,
    // so no other socket can take it mid-poll. The listening socket closes only after the acceptor's
    // cancel handler ran, which GCD runs once no accept handler is running. The clients are awaited
    // after that, because the accept handler is the only thing that starts one: the group can only
    // empty. The pump is awaited last, so no source of it can fire on the descriptors closed below.
    private func performTeardown() {
        acceptor?.cancel()
        keepAliveTask?.cancel()
        pump.stop()

        shutdown(socketFD, SHUT_RDWR)

        let pump = self.pump
        let chain = self.chain
        let relayQueue = self.relayQueue
        let clientRelays = self.clientRelays
        let listenFD = self.listenFD
        let acceptor = self.acceptor
        let keepAliveTask = self.keepAliveTask
        let connectionId = self.connectionId
        Task.detached {
            await acceptor?.waitForCancellation()
            await keepAliveTask?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                clientRelays.notify(queue: relayQueue) { continuation.resume() }
            }
            await pump.waitUntilStopped()

            Darwin.close(listenFD)
            LibSSH2TunnelFactory.cleanupChain(chain, reason: "Closing remote SQLite session")
            Self.logger.info("Remote SQLite session closed for \(connectionId)")
        }
    }

    // MARK: - Accept

    private func spawnClient(
        clientFD: Int32,
        budget: ConnectionRelayDeadlineProvider.Budget
    ) {
        let clientRelays = self.clientRelays
        clientRelays.enter()
        relayQueue.async { [weak self] in
            guard let self else {
                Darwin.close(clientFD)
                clientRelays.leave()
                return
            }
            if !self.admitAndRelay(clientFD: clientFD, budget: budget) {
                clientRelays.leave()
            }
        }
    }

    // True once the relay owns the client, which then leaves `clientRelays` when its channel is freed.
    private func admitAndRelay(
        clientFD: Int32,
        budget: ConnectionRelayDeadlineProvider.Budget
    ) -> Bool {
        let connectionDeadline = budget.deadline
        guard let line = Self.readAdmissionLine(clientFD, deadline: connectionDeadline),
              RemoteSQLiteAdmission.isAuthorized(line: line, token: token) else {
            if budget.isInitial, connectionDeadline.isExpired {
                recordConnectionTimeout(connectionDeadline)
            }
            Self.logger.warning("Remote SQLite client rejected: bad or missing token")
            Darwin.close(clientFD)
            return false
        }

        let opener = RemoteSQLiteExecChannelOpener(session: session, command: command, pump: pump)
        let openPump = SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { [weak self] in
                guard self?.isRunning == true else { return false }
                return !connectionDeadline.isExpired
            },
            deadline: .distantFuture,
            pollForReadiness: { [weak self] directions in
                guard let self else { return false }
                _ = pollReady(
                    fd: self.socketFD,
                    directions: directions,
                    timeoutMs: min(
                        LibSSH2ForwardChannel.openPollTimeoutMs,
                        Int32(clamping: max(1, connectionDeadline.remainingMilliseconds))
                    )
                )
                return !connectionDeadline.isExpired
            }
        )

        let outcome = openPump.run()
        let initialDeadlineTimedOut: Bool
        switch outcome {
        case .timedOut:
            initialDeadlineTimedOut = true
        case .opened, .cancelled, .failed:
            initialDeadlineTimedOut = connectionDeadline.isExpired
        }
        if initialDeadlineTimedOut {
            if budget.isInitial {
                recordConnectionTimeout(connectionDeadline)
            }
            if case .opened(let channel) = outcome {
                Darwin.close(clientFD)
                freeChannel(channel)
                return false
            }
        }

        switch outcome {
        case .opened(let channel):
            relayChannel(clientFD: clientFD, channel: channel)
            return true
        case .failed(let code, let message):
            Self.logger.error("Remote SQLite exec channel failed to open, libssh2 \(code): \(message)")
            Darwin.close(clientFD)
        case .timedOut, .cancelled:
            Darwin.close(clientFD)
        }
        // The channel may have opened and then failed or run out of time on the exec request. The open
        // pump never took ownership, so free it here rather than leak it on the live session.
        if let channel = opener.abandon(transportFD: socketFD) {
            freeAbandonedChannel(channel)
        }
        return false
    }

    private func recordConnectionTimeout(_ deadline: ConnectionDeadline) {
        connectionTimeoutFailure.withLock {
            $0 = deadline.timeoutError(for: chain.timeoutEndpoint)
        }
    }

    /// Reads the token line the client sends before any protocol frame. One byte at a time up to the
    /// newline, so the first protocol bytes that follow it stay in the socket for the relay, with a
    /// receive timeout and a length cap so a silent or hostile client cannot hold the slot open.
    private static func readAdmissionLine(
        _ clientFD: Int32,
        deadline: ConnectionDeadline
    ) -> Data? {
        guard !deadline.isExpired else { return nil }
        defer {
            var clear = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &clear, socklen_t(MemoryLayout<timeval>.size))
        }

        var line = Data()
        var byte: UInt8 = 0
        while line.count <= RemoteSQLiteAdmission.maxLineLength {
            guard !deadline.isExpired else { return nil }
            let timeoutMilliseconds = min(
                admissionTimeoutSeconds * 1_000,
                max(1, deadline.remainingMilliseconds)
            )
            var timeout = timeval(
                tv_sec: timeoutMilliseconds / 1_000,
                tv_usec: Int32(timeoutMilliseconds % 1_000) * 1_000
            )
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            )
            let read = recv(clientFD, &byte, 1, 0)
            if read <= 0 { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }

    private func relayChannel(clientFD: Int32, channel: OpaquePointer) {
        let clientRelays = self.clientRelays
        let handle = ChannelHandle(pointer: channel)
        pump.relay(
            localFD: clientFD,
            channel: LibSSH2ChannelIO(channel: channel, session: session),
            bufferSize: Self.relayBufferSize,
            byteCounter: byteCounter
        ) { [weak self] termination in
            defer { clientRelays.leave() }
            guard let self, self.isRunning else { return }

            self.freeChannel(handle.pointer)

            if termination == .transportHangup {
                Self.logger.info("Remote SQLite transport hung up for \(self.connectionId)")
                self.markDead()
            }
        }
    }

    // EOF closes the agent's standard input so it exits. sshd answers the CLOSE only once the agent
    // has, so the free has no deadline; it runs off the session queue and ends with the session.
    private func freeChannel(_ channel: OpaquePointer) {
        _ = LibSSH2ChannelFree.run(
            channel: channel,
            session: session,
            pump: pump,
            transportFD: socketFD,
            deadline: .distantFuture,
            isActive: { [weak self] in self?.isRunning ?? false }
        )
    }

    // A channel given up on mid-open may hold its exec request half sent, which no call finishes once the
    // open stopped, so its free has the keep-alive's limit and a stuck one ends the session.
    private func freeAbandonedChannel(_ channel: OpaquePointer) {
        let outcome = LibSSH2ChannelFree.run(
            channel: channel,
            session: session,
            pump: pump,
            transportFD: socketFD,
            isActive: { [weak self] in self?.isRunning ?? false }
        )
        guard outcome == .timedOut else { return }
        Self.logger.warning("Remote SQLite channel did not close within \(Int(LibSSH2ChannelFree.deadlineSeconds))s, marking dead")
        markDead()
    }
}
