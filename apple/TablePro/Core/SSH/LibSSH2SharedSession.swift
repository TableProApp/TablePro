//
//  LibSSH2SharedSession.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

import TableProSSHTransport

// One authenticated SSH transport that every database connection on the same route opens its channels on, the
// model of OpenSSH's ControlMaster: one handshake, one sign-in and one keep-alive however many connections ride
// it. It owns the TCP socket, the session, the jump hops and the pump that serves every channel's relay; each
// connection's listener lives in its own LibSSH2Tunnel.
internal final class LibSSH2SharedSession: SSHSharedTransport, @unchecked Sendable {
    let dialedRoute: DialedSSHRoute
    let timeoutEndpoint: ConnectionTimeoutEndpoint

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2SharedSession")

    private let session: OpaquePointer
    private let socketFD: Int32
    private let jumpChain: [LibSSH2TunnelFactory.AuthenticatedChain.HopInfo]
    private let label: String
    private let aliveLatch = TeardownLatch()

    // Every libssh2 call on the session, and the relays of its channels.
    private let pump: SSHSessionPump

    // Every channel from the start of its open until it is freed or given up, so teardown frees the session only
    // once nothing can touch it. A channel is admitted under the same lock that closes admission, so none starts
    // after teardown began waiting.
    private let channels = DispatchGroup()
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var admitting = true
        var deathHandlers: [UUID: @Sendable () -> Void] = [:]
        var keepAliveTask: Task<Void, Never>?
    }

    // libssh2 keeps one channel open's state per session (session->open_state): a call made while another open
    // is pending carries that open on, request and all, and takes its channel. Opens therefore queue, and one a
    // caller gave up on is settled before the next starts (`settleAbandonedOpen`).
    private let openTurn = DispatchSemaphore(value: 1)
    private static let openTurnWaitMs = 100

    private static let relayBufferSize = 32_768

    // Process termination closes every session without waiting, from a synchronous context.
    private static let live = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: LibSSH2SharedSession]())

    init(chain: LibSSH2TunnelFactory.AuthenticatedChain, label: String) {
        self.session = chain.session
        self.socketFD = chain.socketFD
        self.jumpChain = chain.jumpHops
        self.dialedRoute = chain.dialedRoute
        self.timeoutEndpoint = chain.timeoutEndpoint
        self.label = label
        self.pump = SSHSessionPump(
            transportFD: chain.socketFD,
            queue: DispatchQueue(label: "com.TablePro.ssh.session.\(label)", qos: .utility)
        )
        Self.live.withLock { $0[ObjectIdentifier(self)] = self }
    }

    var isRunning: Bool {
        aliveLatch.isLive
    }

    // Puts the session in non-blocking mode for the pump and starts the keep-alive.
    func start() {
        pump.perform {
            libssh2_session_set_blocking(session, 0)
            LibSSH2KeepAlive.configure(session: session)
        }
        let task = Task.detached { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                let outcome = await self.pump.performAsync {
                    LibSSH2KeepAlive.send(session: self.session, transportFD: self.socketFD)
                }
                if outcome.failed {
                    Self.logger.warning("Keep-alive failed, marking the SSH session dead (\(self.label, privacy: .public))")
                    self.markDead()
                    return
                }
                try? await Task.sleep(for: .seconds(outcome.secondsToNext))
            }
        }
        state.withLock { $0.keepAliveTask = task }
    }

    // MARK: - Holders

    // Called once, off this session's queues, when the transport dies. False when it already has, so the caller
    // can treat the session as gone.
    @discardableResult
    func addDeathHandler(id: UUID, _ handler: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state -> Bool in
            guard state.admitting else { return false }
            state.deathHandlers[id] = handler
            return true
        }
    }

    func removeDeathHandler(id: UUID) {
        state.withLock { _ = $0.deathHandlers.removeValue(forKey: id) }
    }

    // MARK: - Channels

    // Blocks the calling thread, so it runs on a dispatch queue. An opened channel stays admitted until it is
    // relayed to its end or handed to `freeChannel`.
    func openChannel(
        destination: SSHForwardDestination,
        originPort: Int,
        deadline: ConnectionDeadline,
        isActive: @escaping () -> Bool
    ) -> ChannelOpenOutcome {
        guard admitChannel() else { return .cancelled }
        while openTurn.wait(timeout: .now() + .milliseconds(Self.openTurnWaitMs)) == .timedOut {
            guard isRunning, !deadline.isExpired, isActive() else {
                channels.leave()
                return deadline.isExpired ? .timedOut : .cancelled
            }
        }

        let opener = PendingAwareOpener(base: LibSSH2ForwardChannelOpener(
            session: session,
            destination: destination,
            originPort: originPort,
            pump: pump,
            turn: SSHSendTurn(pump: pump)
        ))
        let outcome = runOpen(opener, deadline: deadline, isActive: { !deadline.isExpired && isActive() })

        if case .opened = outcome {
            opener.finish()
            openTurn.signal()
            return outcome
        }
        if opener.isPending, isRunning {
            // libssh2 still holds this request as the session's pending open, maybe with its packet half sent,
            // which only the open itself can finish and which holds every other send on the session meanwhile.
            // It is driven to its end here, off the caller, before the next open may start.
            DispatchQueue.global(qos: .utility).async { [self] in
                settleAbandonedOpen(opener)
                opener.finish()
                openTurn.signal()
                channels.leave()
            }
            return outcome
        }
        opener.finish()
        openTurn.signal()
        channels.leave()
        if case .failed(let code, _) = outcome, Self.isTransportFailure(code) {
            Self.logger.warning("SSH transport failed during a channel open, marking the session dead (\(self.label, privacy: .public))")
            markDead()
        }
        return outcome
    }

    private func runOpen(
        _ opener: PendingAwareOpener,
        deadline: ConnectionDeadline,
        isActive: @escaping () -> Bool
    ) -> ChannelOpenOutcome {
        let socketFD = self.socketFD
        return SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { [weak self] in
                guard let self, self.isRunning else { return false }
                return isActive()
            },
            deadline: .distantFuture,
            pollForReadiness: { directions in
                _ = pollReady(
                    fd: socketFD,
                    directions: directions,
                    timeoutMs: min(
                        LibSSH2ForwardChannel.openPollTimeoutMs,
                        Int32(clamping: max(1, deadline.remainingMilliseconds))
                    )
                )
                return !deadline.isExpired
            }
        ).run()
    }

    // The server answers an open once its own connect to the destination ends, which behind a firewall that drops
    // the SYN takes as long as its kernel retries (127 s on Linux). A session whose open outlasts that is ended.
    private static let abandonedOpenLimitSeconds = 150

    private func settleAbandonedOpen(_ opener: PendingAwareOpener) {
        let limit = ConnectionDeadline(configuredSeconds: Self.abandonedOpenLimitSeconds)
        switch runOpen(opener, deadline: limit, isActive: { !limit.isExpired }) {
        case .opened(let channel):
            channels.enter()
            freeChannel(channel)
        case .failed(let code, _) where Self.isTransportFailure(code):
            markDead()
        case .failed:
            break
        case .timedOut, .cancelled:
            guard isRunning else { return }
            Self.logger.warning("An abandoned channel open never settled, marking the SSH session dead (\(self.label, privacy: .public))")
            markDead()
        }
    }

    // Takes ownership of `clientFD`, which the pump closes. The channel is freed before `onEnd` runs.
    @discardableResult
    func relay(
        clientFD: Int32,
        channel: OpaquePointer,
        byteCounter: (any RelayByteObserver)?,
        onEnd: @escaping @Sendable (RelayTermination) -> Void
    ) -> SSHSessionPump.RelayID {
        let handle = ChannelHandle(pointer: channel)
        return pump.relay(
            localFD: clientFD,
            channel: LibSSH2ChannelIO(channel: channel, session: session),
            bufferSize: Self.relayBufferSize,
            byteCounter: byteCounter
        ) { [weak self] termination in
            defer { onEnd(termination) }
            guard let self else { return }
            if termination == .transportHangup {
                self.channels.leave()
                Self.logger.info("SSH transport hung up, marking the session dead (\(self.label, privacy: .public))")
                self.markDead()
            } else {
                self.freeChannel(handle.pointer)
            }
        }
    }

    // One tunnel closing ends its own relays; the session's other tunnels keep theirs.
    func endRelay(_ id: SSHSessionPump.RelayID) {
        pump.endRelay(id)
    }

    // Blocks up to `LibSSH2ChannelFree.deadlineSeconds`. Once the session stopped, its own free releases the channel.
    func freeChannel(_ channel: OpaquePointer) {
        defer { channels.leave() }
        guard isRunning else { return }
        let outcome = LibSSH2ChannelFree.run(
            channel: channel,
            session: session,
            pump: pump,
            transportFD: socketFD,
            isActive: { [weak self] in self?.isRunning ?? false }
        )
        if outcome == .timedOut {
            Self.logger.warning(
                "A channel did not close within \(Int(LibSSH2ChannelFree.deadlineSeconds))s, marking the SSH session dead (\(self.label, privacy: .public))"
            )
            markDead()
        }
    }

    private func admitChannel() -> Bool {
        state.withLock { state -> Bool in
            guard state.admitting else { return false }
            channels.enter()
            return true
        }
    }

    // libssh2 reports a dead transport as a socket error; a server's refusal of one channel is CHANNEL_FAILURE.
    private static func isTransportFailure(_ code: Int32) -> Bool {
        code == LIBSSH2_ERROR_SOCKET_SEND || code == LIBSSH2_ERROR_SOCKET_RECV || code == LIBSSH2_ERROR_SOCKET_DISCONNECT
    }

    // MARK: - Lifecycle

    // The last holder let go.
    func close() {
        guard aliveLatch.claim() else { return }
        performTeardown(notifying: false)
    }

    private func markDead() {
        guard aliveLatch.claim() else { return }
        performTeardown(notifying: true)
    }

    // `shutdown` wakes every open, free and relay waiting on the transport but keeps the descriptor number, so no
    // other socket can take it mid-poll. The holders hear of a death first, so they give back the channels they
    // hold; the session is freed once every channel is, after the pump's last call.
    private func performTeardown(notifying: Bool) {
        let (handlers, keepAliveTask) = state.withLock { state in
            state.admitting = false
            let handlers = Array(state.deathHandlers.values)
            state.deathHandlers.removeAll()
            return (handlers, state.keepAliveTask)
        }
        keepAliveTask?.cancel()
        pump.stop()
        shutdown(socketFD, SHUT_RDWR)
        if notifying {
            DispatchQueue.global(qos: .utility).async {
                handlers.forEach { $0() }
            }
        }

        let pump = self.pump
        let channels = self.channels
        let session = self.session
        let socketFD = self.socketFD
        let jumpChain = self.jumpChain
        let label = self.label
        let identity = ObjectIdentifier(self)
        Task.detached {
            await keepAliveTask?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                channels.notify(queue: .global(qos: .utility)) { continuation.resume() }
            }
            await pump.waitUntilStopped()

            // Free before close: a closed number can go to another connection's socket, and this session's
            // DISCONNECT would land in it.
            pump.perform {
                libssh2_session_set_blocking(session, 1)
                tablepro_libssh2_session_disconnect(session, "Closing tunnel")
                libssh2_session_free(session)
                Darwin.close(socketFD)
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
            Self.live.withLock { _ = $0.removeValue(forKey: identity) }
            Self.logger.info("SSH session closed (\(label, privacy: .public))")
        }
    }

    // App termination: waits for nothing, closes no descriptor and frees no session, since a relay may still be
    // using them and the OS reclaims them all.
    private func closeSync() {
        guard aliveLatch.claim() else { return }
        state.withLock { $0.admitting = false }
        pump.stop()
        shutdown(socketFD, SHUT_RDWR)
        for hop in jumpChain.reversed() {
            hop.relay.stop()
            shutdown(hop.socket, SHUT_RDWR)
        }
    }

    static func closeAllSync() {
        let sessions = live.withLock { sessions -> [LibSSH2SharedSession] in
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        sessions.forEach { $0.closeSync() }
    }

    private struct ChannelHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }
}

// Knows whether libssh2 still holds this open as the session's pending one: true once an attempt would block,
// false again once one opened or failed. Touched by one thread at a time, the one driving the open.
private final class PendingAwareOpener: SSHForwardChannelOpening, @unchecked Sendable {
    private let base: LibSSH2ForwardChannelOpener
    private(set) var isPending = false

    init(base: LibSSH2ForwardChannelOpener) {
        self.base = base
    }

    func attemptOpen() -> SSHForwardChannelAttempt {
        let attempt = base.attemptOpen()
        if case .wouldBlock = attempt {
            isPending = true
        } else {
            isPending = false
        }
        return attempt
    }

    func finish() {
        base.turn.end()
    }
}
