//
//  LibSSH2Tunnel.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

import TableProSSHTransport

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

    /// Dedicated queue for the accept loop (poll + accept only, no libssh2 calls).
    private let acceptQueue: DispatchQueue

    /// Callback invoked when the tunnel dies (keep-alive failure, etc.)
    var onDeath: ((UUID) -> Void)?

    private let forwardFailure = SSHForwardFailureRecorder()

    /// Shared by every client relay this tunnel serves, so the readout describes the tunnel rather
    /// than whichever socket the driver happens to be using. Owned here and registered weakly, so
    /// the totals disappear with the tunnel instead of outliving it.
    private let byteCounter = TransportByteCounter()

    struct JumpHop {
        let session: OpaquePointer    // LIBSSH2_SESSION*
        let socket: Int32             // TCP or socketpair fd
        let channel: OpaquePointer    // LIBSSH2_CHANNEL* (direct-tcpip to next hop)
        let relayTask: Task<Void, Never>?  // socketpair relay task (nil for first hop)
    }

    private static let relayBufferSize = 32_768 // 32KB

    /// Bounds a forwarding channel open for a client that has already been accepted. libssh2
    /// retries EAGAIN forever on its own, so without this a stuck open outlives the database
    /// driver's connect timeout and the client waits on a socket nothing will ever write to.
    /// Held strictly below every bundled driver's connect timeout (10s for MySQL, PostgreSQL,
    /// Redis, MongoDB, and Cassandra) so the failure recorded here reaches the user before the
    /// driver reports its own timeout, which names no cause. An equal budget loses that race:
    /// the driver's clock starts when it dials, this one only once the accept has been noticed.
    /// A registry plugin with a shorter connect timeout is not covered, because a plugin's
    /// C-level timeout cannot be read from here.
    internal static let channelOpenDeadlineSeconds: TimeInterval = 6
    private static let channelOpenPollTimeoutMs: Int32 = 5_000

    /// How long the accept loop waits per poll before rechecking `isRunning`. Small enough that
    /// noticing a client the kernel already accepted costs a slim part of the margin above.
    internal static let acceptPollTimeoutMs: Int32 = 200

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
        TransportActivityRegistry.shared.register(byteCounter, for: connectionId)
    }

    var isRunning: Bool {
        aliveLatch.isLive
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
                        guard let client = self.acceptClient() else {
                            if self.isRunning {
                                continue
                            }
                            break
                        }

                        self.spawnClient(
                            clientFD: client.fd,
                            acceptedAt: client.acceptedAt,
                            destination: destination
                        )
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

    /// Breaks every blocking wait first, then frees the session and the descriptors only once
    /// every task that could still be polling them has exited. `shutdown` unblocks a poll at
    /// once without releasing the descriptor number, which another thread would otherwise be
    /// free to receive from the kernel and poll by mistake. `shutdown` does not wake a poll on a
    /// listening socket on Darwin, so the accept loop ends on the latch instead, inside one
    /// `acceptPollTimeoutMs`, and its descriptor closes once it has.
    ///
    /// The relays are waited on after the accept loop, not alongside it, because the accept loop
    /// is the only thing that starts one: once it has ended, the group can only empty.
    private func performTeardown() {
        forwardingTask?.cancel()
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
        let forwardingTask = self.forwardingTask
        let keepAliveTask = self.keepAliveTask
        Task.detached {
            await forwardingTask?.value
            await keepAliveTask?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                clientRelays.notify(queue: relayQueue) { continuation.resume() }
            }

            sessionQueue.sync {
                Darwin.close(listenFD)
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

    /// Synchronous cleanup for app termination, which waits for nothing because the process is
    /// exiting. No descriptor is closed and the session is not freed: the relays and the accept
    /// loop may still be polling them, and the OS reclaims every one of them anyway.
    func closeSync() {
        guard consumeAliveLatch() else { return }

        forwardingTask?.cancel()
        keepAliveTask?.cancel()

        shutdown(socketFD, SHUT_RDWR)

        for hop in jumpChain.reversed() {
            hop.relayTask?.cancel()
        }
    }

    // MARK: - Private

    private func markDead() {
        guard consumeAliveLatch() else { return }
        performTeardown()
        onDeath?(connectionId)
    }

    /// Accepts a client on the listening socket. The accept timestamp is taken here, not once
    /// the open reaches `openAndRelay`, because the client's own connect timeout is already
    /// running by then and the scheduling hops in between would push the deadline past it.
    private func acceptClient() -> (fd: Int32, acceptedAt: Date)? {
        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, Self.acceptPollTimeoutMs)

        guard pollResult > 0, pollFD.revents & Int16(POLLIN) != 0 else {
            return nil
        }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &addrLen)
            }
        }

        guard clientFD >= 0 else { return nil }
        return (clientFD, Date())
    }

    /// Open the channel and relay the client, off the accept loop so a slow open cannot
    /// stall the next accept, and off `sessionQueue` between attempts so it cannot stall
    /// the relays and keep-alive that share the session.
    private func openAndRelay(clientFD: Int32, acceptedAt: Date, destination: SSHForwardDestination) {
        let pump = SSHForwardChannelOpenPump(
            opener: LibSSH2ForwardChannelOpener(
                session: session,
                destination: destination,
                originPort: localPort,
                sessionQueue: sessionQueue
            ),
            isActive: { [weak self] in self?.isRunning ?? false },
            deadline: acceptedAt.addingTimeInterval(Self.channelOpenDeadlineSeconds),
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
        forwardFailure.record(
            outcome,
            destination: destination,
            deadlineSeconds: Int(Self.channelOpenDeadlineSeconds)
        )
        handleChannelOpenOutcome(outcome, clientFD: clientFD) { channel in
            runRelay(clientFD: clientFD, channel: channel, destination: destination)
        }
    }

    func consumeLastForwardFailure() -> SSHTunnelError? {
        forwardFailure.consume()?.tunnelError
    }

    private func logChannelOpenOutcome(_ outcome: ChannelOpenOutcome, destination: SSHForwardDestination) {
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
                "Forwarding channel to \(target) did not open within \(Int(Self.channelOpenDeadlineSeconds))s, closing local socket"
            )
        case .cancelled:
            break
        }
    }

    /// Opens the channel and relays one accepted client, off the accept loop so a slow
    /// open cannot delay the next accept. The loop runs on `relayQueue` (concurrent);
    /// individual libssh2 calls are dispatched to `sessionQueue` (serial) for thread safety.
    private func spawnClient(clientFD: Int32, acceptedAt: Date, destination: SSHForwardDestination) {
        let clientRelays = self.clientRelays
        clientRelays.enter()
        relayQueue.async { [weak self] in
            defer { clientRelays.leave() }
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            self.openAndRelay(clientFD: clientFD, acceptedAt: acceptedAt, destination: destination)
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
