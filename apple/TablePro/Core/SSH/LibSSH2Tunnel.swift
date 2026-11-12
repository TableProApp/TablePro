//
//  LibSSH2Tunnel.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

import TableProSSHTransport

// An SSH tunnel backed by libssh2. It owns the TCP socket, the session, the local listening socket
// with its acceptor, and the keep-alive task.
internal final class LibSSH2Tunnel: @unchecked Sendable {
    let connectionId: UUID
    let localPort: Int
    let dialedRoute: DialedSSHRoute?
    let createdAt: Date

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2Tunnel")

    private let session: OpaquePointer           // LIBSSH2_SESSION*
    private let socketFD: Int32                   // TCP socket to SSH server
    private let listenFD: Int32                   // Local listening socket

    // Jump host chain (in connection order)
    private let jumpChain: [JumpHop]

    private var acceptor: SSHListenerAcceptor?
    private var keepAliveTask: Task<Void, Never>?
    private let aliveLatch = TeardownLatch()

    /// The relays still running, so teardown frees the session only once none of them can touch
    /// it. A group rather than a collection of tasks: a relay leaves it by finishing, which is the
    /// one thing a `[Task]` pruned on `isCancelled` never noticed, so a tunnel that had served
    /// clients carried every one of them until it closed. It is also all a task was ever worth
    /// here, since the relay runs on `relayQueue` outside the task's cancellation scope and stops
    /// on `aliveLatch` rather than on `Task.isCancelled`.
    private let clientRelays = DispatchGroup()

    /// Serial queue for all libssh2 calls on this tunnel's session.
    /// libssh2 is not thread-safe per session, so every call must be serialized.
    private let sessionQueue: DispatchQueue

    /// Concurrent queue for relay I/O (poll, send, recv — no libssh2 calls).
    /// Individual libssh2 calls within each relay are dispatched to `sessionQueue`.
    private let relayQueue: DispatchQueue

    // Serial: the acceptor's handler, which accepts and makes no libssh2 call.
    private let acceptQueue: DispatchQueue

    /// Callback invoked when the tunnel dies (keep-alive failure, etc.)
    var onDeath: ((UUID) -> Void)?

    private let forwardFailure = SSHForwardFailureRecorder()
    private let connectionTimeoutFailure = OSAllocatedUnfairLock<ConnectionTimeoutError?>(initialState: nil)
    private let relayDeadlines: ConnectionRelayDeadlineProvider
    private let timeoutEndpoint: ConnectionTimeoutEndpoint

    /// Shared by every client relay this tunnel serves, so the readout describes the tunnel rather
    /// than whichever socket the driver happens to be using. Owned here and registered weakly, so
    /// the totals disappear with the tunnel instead of outliving it.
    private let byteCounter = TransportByteCounter()

    struct JumpHop {
        let session: OpaquePointer    // LIBSSH2_SESSION*
        let socket: Int32             // TCP or socketpair fd
        let channel: OpaquePointer    // LIBSSH2_CHANNEL* (direct-tcpip to next hop)
        let relay: SSHJumpRelayFence  // owns the socketpair relay's handle-lifetime fence
    }

    private static let relayBufferSize = 32_768 // 32KB

    init(
        connectionId: UUID,
        localPort: Int,
        session: OpaquePointer,
        socketFD: Int32,
        listenFD: Int32,
        connectionDeadline: ConnectionDeadline,
        timeoutEndpoint: ConnectionTimeoutEndpoint,
        jumpChain: [JumpHop] = [],
        dialedRoute: DialedSSHRoute? = nil
    ) {
        self.connectionId = connectionId
        self.localPort = localPort
        self.dialedRoute = dialedRoute
        self.session = session
        self.socketFD = socketFD
        self.listenFD = listenFD
        self.relayDeadlines = ConnectionRelayDeadlineProvider(initialDeadline: connectionDeadline)
        self.timeoutEndpoint = timeoutEndpoint
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
        TransportActivityRegistry.shared.register(byteCounter, for: connectionId)
    }

    var isRunning: Bool {
        aliveLatch.isLive
    }

    // MARK: - Forwarding

    func startForwarding(destination: SSHForwardDestination) {
        sessionQueue.sync { libssh2_session_set_blocking(session, 0) }

        // A handler already running when the latch is claimed may still spawn one relay; teardown
        // waits for the cancel handler before the relay group, so it waits for that relay too.
        let acceptor = SSHListenerAcceptor(listenFD: listenFD, queue: acceptQueue) { [weak self] client in
            guard let self, self.isRunning else {
                Darwin.close(client.descriptor)
                return
            }
            self.spawnClient(
                clientFD: client.descriptor,
                budget: self.relayDeadlines.next(),
                destination: destination
            )
        }
        self.acceptor = acceptor
        acceptor.start()

        let target = destination.logDescription
        Self.logger.info("Forwarding started on port \(self.localPort) -> \(target)")
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
                        continuation.resume(returning: sshKeepAliveDidFail(rc))
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
        guard consumeAliveLatch() else { return }
        performTeardown()
    }

    /// Takes the one-shot alive latch, returning true to exactly one caller.
    ///
    /// The latch decides who performs teardown, so every path that consumes it owes the teardown.
    /// `markDead` used to consume it and only fire `onDeath`, which left `close()` a no-op for the
    /// rest of the tunnel's life and every resource it held unreleased.
    private func consumeAliveLatch() -> Bool {
        aliveLatch.claim()
    }

    // `shutdown` wakes every poll on the transport but keeps the descriptor number, so no other
    // socket can take it mid-poll. The listening socket closes only after the acceptor's cancel
    // handler ran, which GCD runs once no accept handler is running. The relays are awaited after
    // that, because the accept handler is the only thing that starts one: the group can only empty.
    private func performTeardown() {
        acceptor?.cancel()
        keepAliveTask?.cancel()

        shutdown(socketFD, SHUT_RDWR)

        let sessionQueue = self.sessionQueue
        let relayQueue = self.relayQueue
        let clientRelays = self.clientRelays
        let session = self.session
        let socketFD = self.socketFD
        let listenFD = self.listenFD
        let jumpChain = self.jumpChain
        let connectionId = self.connectionId
        let acceptor = self.acceptor
        let keepAliveTask = self.keepAliveTask
        Task.detached {
            await acceptor?.waitForCancellation()
            await keepAliveTask?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                clientRelays.notify(queue: relayQueue) { continuation.resume() }
            }

            // Free before close: a closed number can go to another connection's socket, and this
            // session's DISCONNECT would land in it.
            sessionQueue.sync {
                libssh2_session_set_blocking(session, 1)
                tablepro_libssh2_session_disconnect(session, "Closing tunnel")
                libssh2_session_free(session)
                Darwin.close(socketFD)
                Darwin.close(listenFD)
            }

            for hop in jumpChain.reversed() {
                hop.relay.stop()
                shutdown(hop.socket, SHUT_RDWR)
            }
            for hop in jumpChain.reversed() {
                await hop.relay.waitForCompletion()
            }
            for hop in jumpChain.reversed() {
                libssh2_channel_free(hop.channel)
                tablepro_libssh2_session_disconnect(hop.session, "Closing")
                libssh2_session_free(hop.session)
                Darwin.close(hop.socket)
            }

            Self.logger.info("Tunnel closed for connection \(connectionId)")
        }
    }

    // App termination: waits for nothing, closes no descriptor and frees no session, since a relay or
    // the accept handler may still be using them and the OS reclaims them all.
    func closeSync() {
        guard consumeAliveLatch() else { return }

        acceptor?.cancel()
        keepAliveTask?.cancel()

        shutdown(socketFD, SHUT_RDWR)

        for hop in jumpChain.reversed() {
            hop.relay.stop()
            shutdown(hop.socket, SHUT_RDWR)
        }
    }

    // MARK: - Private

    private func markDead() {
        guard consumeAliveLatch() else { return }
        performTeardown()
        onDeath?(connectionId)
    }

    // Off `sessionQueue` between open attempts, so a slow open cannot stall the relays and the
    // keep-alive that share the session.
    private func openAndRelay(
        clientFD: Int32,
        budget: ConnectionRelayDeadlineProvider.Budget,
        destination: SSHForwardDestination
    ) {
        let connectionDeadline = budget.deadline
        let pump = SSHForwardChannelOpenPump(
            opener: LibSSH2ForwardChannelOpener(
                session: session,
                destination: destination,
                originPort: localPort,
                sessionQueue: sessionQueue
            ),
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

        let outcome = pump.run()
        let relayTimedOut: Bool
        switch outcome {
        case .timedOut:
            relayTimedOut = true
        case .opened, .cancelled, .failed:
            relayTimedOut = connectionDeadline.isExpired
        }
        if relayTimedOut {
            if budget.isInitial {
                connectionTimeoutFailure.withLock {
                    $0 = connectionDeadline.timeoutError(for: timeoutEndpoint)
                }
            }
            if case .opened(let channel) = outcome {
                Darwin.close(clientFD)
                freeChannel(channel)
                return
            }
        }
        let deadlineSeconds = connectionDeadline.configuredSeconds
        logChannelOpenOutcome(
            outcome,
            destination: destination,
            deadlineSeconds: deadlineSeconds
        )
        forwardFailure.record(
            outcome,
            destination: destination,
            deadlineSeconds: deadlineSeconds
        )
        handleChannelOpenOutcome(outcome, clientFD: clientFD) { channel in
            runRelay(clientFD: clientFD, channel: channel, destination: destination)
        }
    }

    func consumeLastForwardFailure() -> (any Error)? {
        if let timeout = connectionTimeoutFailure.withLock({ failure -> ConnectionTimeoutError? in
            defer { failure = nil }
            return failure
        }) {
            return timeout
        }
        return forwardFailure.consume()?.tunnelError
    }

    private func logChannelOpenOutcome(
        _ outcome: ChannelOpenOutcome,
        destination: SSHForwardDestination,
        deadlineSeconds: Int
    ) {
        let target = destination.logDescription
        switch outcome {
        case .opened:
            Self.logger.debug("Client connected, relaying to \(target)")
        case .failed(let errorCode, let message):
            Self.logger.error(
                "Forwarding channel to \(target) failed to open, libssh2 error \(errorCode): \(message)"
            )
        case .timedOut:
            Self.logger.error(
                "Forwarding channel to \(target) did not open within \(deadlineSeconds)s, closing local socket"
            )
        case .cancelled:
            break
        }
    }

    // On `relayQueue`, off the accept handler, so a slow open cannot delay the next accept.
    private func spawnClient(
        clientFD: Int32,
        budget: ConnectionRelayDeadlineProvider.Budget,
        destination: SSHForwardDestination
    ) {
        let clientRelays = self.clientRelays
        clientRelays.enter()
        relayQueue.async { [weak self] in
            defer { clientRelays.leave() }
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            self.openAndRelay(clientFD: clientFD, budget: budget, destination: destination)
        }
    }

    /// Blocking relay loop. Runs on `relayQueue`; libssh2 calls go through `sessionQueue`.
    /// Every termination is logged, not just a hangup: a channel that opens only after the
    /// database client already gave up ends as `.localClosed`, and staying silent about that
    /// leaves no trace of a tunnel that worked but arrived too late.
    private func runRelay(clientFD: Int32, channel: OpaquePointer, destination: SSHForwardDestination) {
        let relay = SSHChannelRelay(
            localFD: clientFD,
            transportFD: socketFD,
            channelIO: LibSSH2ChannelIO(channel: channel, session: session, sessionQueue: sessionQueue),
            bufferSize: Self.relayBufferSize,
            isActive: { [weak self] in self?.isRunning ?? false },
            byteCounter: byteCounter
        )

        let startedAt = Date()
        let termination = relay.run()
        let elapsed = Date().timeIntervalSince(startedAt)

        let target = destination.logDescription
        Self.logger.debug(
            "Relay to \(target) ended as \(String(describing: termination)) after \(elapsed, format: .fixed(precision: 1))s"
        )

        Darwin.close(clientFD)
        guard self.isRunning else { return }

        freeChannel(channel)

        if termination == .transportHangup {
            Self.logger.info("SSH transport hung up, marking tunnel dead for \(self.connectionId)")
            markDead()
        }
    }

    private func freeChannel(_ channel: OpaquePointer) {
        let outcome = LibSSH2ChannelFree.run(
            channel: channel,
            session: session,
            sessionQueue: sessionQueue,
            transportFD: socketFD,
            isActive: { [weak self] in self?.isRunning ?? false }
        )
        if outcome == .timedOut {
            Self.logger.warning(
                "Channel for \(self.connectionId) did not close within \(Int(LibSSH2ChannelFree.deadlineSeconds))s, marking tunnel dead"
            )
            markDead()
        }
    }
}
