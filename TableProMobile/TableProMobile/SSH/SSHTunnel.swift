import CLibSSH2
import Foundation
import os
import TableProSSHTransport

/// One authenticated libssh2 session forwarding a local port, built by `SSHTunnelFactory`.
///
/// A class rather than an actor, the shape `LibSSH2Tunnel` already has on macOS. Every libssh2
/// call is serialized on `sessionQueue`, the accept loop has a serial queue of its own and the
/// relays share a concurrent one, so nothing here blocks a thread of Swift's cooperative pool.
/// An actor gives mutual exclusion but never thread transfer, so a tunnel parked in `poll` held
/// a cooperative thread for its whole life: measured, 48 tunnels ran 12 at a time in 4,005ms
/// where queues ran all 48 in 1,003ms. `Task.detached` measured the same 12, because it is the
/// same pool.
///
/// Its socket, session and listening socket are `let`, established before construction, so there
/// is no mutable state to protect and `close()` is synchronous.
nonisolated final class SSHTunnel: @unchecked Sendable {
    let localPort: Int

    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnel")

    private let session: OpaquePointer
    private let socketFD: Int32
    private let listenFD: Int32

    /// Serial: every libssh2 call on this session. libssh2 is not thread-safe per session.
    private let sessionQueue: DispatchQueue

    /// Concurrent: relay loops, which poll, send and recv but make no libssh2 call directly.
    private let relayQueue: DispatchQueue

    /// Serial: the accept loop, which polls the listening socket and nothing else.
    private let acceptQueue: DispatchQueue

    private let aliveLatch = TeardownLatch()

    /// The relays still running, so teardown frees the session only once none of them can touch
    /// it. A group rather than a collection of tasks: a relay leaves it by finishing, which is the
    /// one thing a `[Task]` pruned on `isCancelled` never noticed, so a tunnel that had served
    /// clients carried every one of them until it closed. It is also all a task was ever worth
    /// here, since the relay runs on `relayQueue` outside the task's cancellation scope and stops
    /// on `aliveLatch` rather than on `Task.isCancelled`.
    private let clientRelays = DispatchGroup()
    private var forwardingTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private static let relayBufferSize = 32_768

    /// Bounds a forwarding channel open for a client that has already been accepted. libssh2
    /// retries EAGAIN forever on its own, so without this a stuck open outlives the database
    /// driver's connect timeout and the client waits on a socket nothing will ever write to.
    /// Held strictly below every iOS driver's connect timeout so the reason reaches the log
    /// before the driver reports its own timeout, which names no cause.
    static let channelOpenDeadlineSeconds: TimeInterval = 6
    private static let channelOpenPollTimeoutMs: Int32 = 5_000

    /// How long the accept loop waits per poll before rechecking the latch. Small enough that
    /// noticing a client the kernel already accepted costs a slim part of the margin above.
    static let acceptPollTimeoutMs: Int32 = 200

    private static let keepAliveIntervalSeconds = 10

    init(
        session: OpaquePointer,
        socketFD: Int32,
        listenFD: Int32,
        localPort: Int,
        sessionQueue: DispatchQueue
    ) {
        self.session = session
        self.socketFD = socketFD
        self.listenFD = listenFD
        self.localPort = localPort
        self.sessionQueue = sessionQueue
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

        forwardingTask = Task.detached { [weak self] in
            guard let self else { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.acceptQueue.async { [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }

                    let target = destination.logDescription
                    Self.logger.info("Forwarding started on port \(self.localPort) -> \(target)")

                    while self.isRunning {
                        guard let client = self.acceptClient() else { continue }
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

                try? await Task.sleep(for: .seconds(Self.keepAliveIntervalSeconds))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        guard aliveLatch.claim() else { return }
        performTeardown()
    }

    private func markDead() {
        guard aliveLatch.claim() else { return }
        performTeardown()
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
        let localPort = self.localPort
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

            Self.logger.info("Tunnel closed (local port \(localPort))")
        }
    }

    // MARK: - Private

    /// The accept timestamp is taken here, not once the open reaches `openAndRelay`, because the
    /// client's own connect timeout is already running by then and the scheduling hops in between
    /// would push the deadline past it.
    private func acceptClient() -> (fd: Int32, acceptedAt: Date)? {
        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, Self.acceptPollTimeoutMs)

        guard pollResult > 0, pollFD.revents & Int16(POLLIN) != 0 else { return nil }

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

    /// Opens the channel and relays one accepted client, off the accept loop so a slow open
    /// cannot delay the next accept. The loop runs on `relayQueue` (concurrent); individual
    /// libssh2 calls are dispatched to `sessionQueue` (serial) for thread safety.
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

        sessionQueue.sync {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
        }

        if termination == .transportHangup {
            Self.logger.info("SSH transport hung up, marking tunnel dead on port \(self.localPort)")
            markDead()
        }
    }
}
