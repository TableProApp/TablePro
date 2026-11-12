import CLibSSH2
import Foundation
import os
import TableProSSHTransport

// One authenticated libssh2 session forwarding a local port, built by `SSHTunnelFactory`.
//
// A class rather than an actor, the shape `LibSSH2Tunnel` already has on macOS. Every libssh2 call
// is serialized on `sessionQueue`, the acceptor has a serial queue of its own and the relays share a
// concurrent one, so nothing here blocks a thread of Swift's cooperative pool. An actor gives mutual
// exclusion but never thread transfer, so a tunnel parked in `poll` held a cooperative thread for its
// whole life: measured, 48 tunnels ran 12 at a time in 4,005ms where queues ran all 48 in 1,003ms.
// `Task.detached` measured the same 12, because it is the same pool.
//
// Its socket, session and listening socket are `let`, established before construction, so `close()`
// is synchronous.
nonisolated final class SSHTunnel: @unchecked Sendable {
    let localPort: Int

    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnel")

    private let session: OpaquePointer
    private let socketFD: Int32
    private let listenFD: Int32
    private let jumpHops: [SSHJumpHop]

    /// Serial: every libssh2 call on this session. libssh2 is not thread-safe per session.
    private let sessionQueue: DispatchQueue

    /// Concurrent: relay loops, which poll, send and recv but make no libssh2 call directly.
    private let relayQueue: DispatchQueue

    // Serial: the acceptor's handler, which accepts and makes no libssh2 call.
    private let acceptQueue: DispatchQueue

    private let aliveLatch = TeardownLatch()
    private let deathNotice = SSHTunnelDeathNotice()

    /// The relays still running, so teardown frees the session only once none of them can touch
    /// it. A group rather than a collection of tasks: a relay leaves it by finishing, which is the
    /// one thing a `[Task]` pruned on `isCancelled` never noticed, so a tunnel that had served
    /// clients carried every one of them until it closed. It is also all a task was ever worth
    /// here, since the relay runs on `relayQueue` outside the task's cancellation scope and stops
    /// on `aliveLatch` rather than on `Task.isCancelled`.
    private let clientRelays = DispatchGroup()
    private var acceptor: SSHListenerAcceptor?
    private var keepAliveTask: Task<Void, Never>?

    private static let relayBufferSize = 32_768

    /// Bounds a forwarding channel open for a client that has already been accepted. libssh2
    /// retries EAGAIN forever on its own, so without this a stuck open outlives the database
    /// driver's connect timeout and the client waits on a socket nothing will ever write to.
    /// Held strictly below every iOS driver's connect timeout so the reason reaches the log
    /// before the driver reports its own timeout, which names no cause.
    static let channelOpenDeadlineSeconds: TimeInterval = 6

    private static let keepAliveIntervalSeconds = 10

    init(
        session: OpaquePointer,
        socketFD: Int32,
        listenFD: Int32,
        localPort: Int,
        sessionQueue: DispatchQueue,
        jumpHops: [SSHJumpHop] = []
    ) {
        self.session = session
        self.socketFD = socketFD
        self.listenFD = listenFD
        self.localPort = localPort
        self.sessionQueue = sessionQueue
        self.jumpHops = jumpHops
        let label = UUID().uuidString
        self.relayQueue = DispatchQueue(label: "com.TablePro.ssh.relay.\(label)", qos: .utility, attributes: .concurrent)
        self.acceptQueue = DispatchQueue(label: "com.TablePro.ssh.accept.\(label)", qos: .utility)
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
                acceptedAt: client.acceptedAt,
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

                try? await Task.sleep(for: .seconds(Self.keepAliveIntervalSeconds))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        guard aliveLatch.claim() else { return }
        performTeardown()
    }

    // A tunnel that stops on its own, unlike close(), which its owner asked for.
    func onDeath(_ handler: @escaping @Sendable () -> Void) {
        deathNotice.onDeath(handler)
    }

    private func markDead() {
        guard aliveLatch.claim() else { return }
        performTeardown()
        deathNotice.died()
    }

    // shutdown wakes every poll on the transport but keeps the number, so no other socket can take it mid-poll.
    // The listening socket closes only after the acceptor's cancel handler ran, once no accept handler is running.
    // The relays are awaited after that, since the accept handler is the only thing that starts one.
    // The hops go last, in the Mac's order.
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
        let jumpHops = self.jumpHops
        let localPort = self.localPort
        let acceptor = self.acceptor
        let keepAliveTask = self.keepAliveTask
        Task.detached {
            await acceptor?.waitForCancellation()
            await keepAliveTask?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                clientRelays.notify(queue: relayQueue) { continuation.resume() }
            }

            // Free before close: a closed number can go to the next tunnel's socket, and this session's DISCONNECT would land in it.
            sessionQueue.sync {
                libssh2_session_set_blocking(session, 1)
                tablepro_libssh2_session_disconnect(session, "Closing tunnel")
                libssh2_session_free(session)
                Darwin.close(socketFD)
                Darwin.close(listenFD)
            }
            await SSHJumpChain.tearDown(jumpHops)

            Self.logger.info("Tunnel closed (local port \(localPort))")
        }
    }

    // MARK: - Private

    // On `relayQueue`, off the accept handler, so a slow open cannot delay the next accept.
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
                _ = pollReady(fd: self.socketFD, directions: directions, timeoutMs: LibSSH2ForwardChannel.openPollTimeoutMs)
                return true
            }
        )

        let outcome = pump.run()
        logChannelOpenOutcome(outcome, destination: destination)
        handleChannelOpenOutcome(outcome, clientFD: clientFD) { channel in
            runRelay(clientFD: clientFD, channel: channel, destination: destination)
        }
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

    private func runRelay(clientFD: Int32, channel: OpaquePointer, destination: SSHForwardDestination) {
        let relay = SSHChannelRelay(
            localFD: clientFD,
            transportFD: socketFD,
            channelIO: LibSSH2ChannelIO(channel: channel, session: session, sessionQueue: sessionQueue),
            bufferSize: Self.relayBufferSize,
            isActive: { [weak self] in self?.isRunning ?? false }
        )

        let startedAt = Date()
        let termination = relay.run()
        let elapsed = Date().timeIntervalSince(startedAt)

        let target = destination.logDescription
        Self.logger.debug(
            "Relay to \(target) ended as \(String(describing: termination)) after \(elapsed, format: .fixed(precision: 1))s"
        )

        Darwin.close(clientFD)
        guard isRunning else { return }

        freeChannel(channel)

        if termination == .transportHangup {
            Self.logger.info("SSH transport hung up, marking tunnel dead on port \(self.localPort)")
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
                "Channel on port \(self.localPort) did not close within \(Int(LibSSH2ChannelFree.deadlineSeconds))s, marking tunnel dead"
            )
            markDead()
        }
    }
}
