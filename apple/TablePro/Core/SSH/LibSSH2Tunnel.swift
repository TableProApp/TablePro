//
//  LibSSH2Tunnel.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

import TableProSSHTransport

// One database connection's way through a shared SSH session: the local listening socket with its acceptor, the
// clients it accepted, and the channel its destination check opened, held for the first client. The session, its
// socket, keep-alive and jump hops belong to LibSSH2SharedSession, which other connections on the same route use too.
internal final class LibSSH2Tunnel: @unchecked Sendable {
    let connectionId: UUID
    let localPort: Int
    let createdAt: Date

    var dialedRoute: DialedSSHRoute? { session.dialedRoute }

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2Tunnel")

    private let session: LibSSH2SharedSession
    private let leaseId: UUID
    private let releaseLease: @Sendable () -> Void
    private let onDeath: @Sendable (LibSSH2Tunnel) -> Void
    private let listenFD: Int32
    private let aliveLatch = TeardownLatch()
    private let acceptor = OSAllocatedUnfairLock<SSHListenerAcceptor?>(initialState: nil)

    // Each accepted client from accept until its relay ended or it was given up, so teardown gives the lease back
    // only once none of them can touch the session.
    private let clients = DispatchGroup()

    // This tunnel's relays on the shared pump, so closing it ends them and leaves the other tunnels' relays alone.
    private let relays = OSAllocatedUnfairLock(initialState: Relays())

    private struct Relays {
        var isClosing = false
        // Every relay from before it starts until it ends, and its pump id once known.
        var running: Set<UUID> = []
        var ids: [UUID: SSHSessionPump.RelayID] = [:]
    }

    private let firstChannel = SSHChannelHandOff()

    // Concurrent: channel opens and frees, which wait on the transport.
    private let relayQueue: DispatchQueue

    // Serial: the acceptor's handler, which accepts and makes no libssh2 call.
    private let acceptQueue: DispatchQueue

    private let forwardFailure = SSHForwardFailureRecorder()
    private let connectionTimeoutFailure = OSAllocatedUnfairLock<ConnectionTimeoutError?>(initialState: nil)
    private let relayDeadlines: ConnectionRelayDeadlineProvider
    private let connectionDeadline: ConnectionDeadline

    /// Shared by every client relay this tunnel serves, so the readout describes the tunnel rather
    /// than whichever socket the driver happens to be using. Owned here and registered weakly, so
    /// the totals disappear with the tunnel instead of outliving it.
    private let byteCounter = TransportByteCounter()

    init(
        connectionId: UUID,
        localPort: Int,
        listenFD: Int32,
        session: LibSSH2SharedSession,
        leaseId: UUID,
        connectionDeadline: ConnectionDeadline,
        releaseLease: @escaping @Sendable () -> Void,
        onDeath: @escaping @Sendable (LibSSH2Tunnel) -> Void
    ) {
        self.connectionId = connectionId
        self.localPort = localPort
        self.listenFD = listenFD
        self.session = session
        self.leaseId = leaseId
        self.releaseLease = releaseLease
        self.onDeath = onDeath
        self.connectionDeadline = connectionDeadline
        self.relayDeadlines = ConnectionRelayDeadlineProvider(initialDeadline: connectionDeadline)
        self.createdAt = Date()
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
        aliveLatch.isLive && session.isRunning
    }

    // MARK: - Opening

    // Confirms the SSH server can reach the destination before the port is handed back: otherwise a destination
    // the server cannot reach stays invisible until the driver dials, where it surfaces as an accepted socket that
    // goes silent and a greeting timeout naming no cause (#1981). The channel this opens is kept for the first
    // client, so the check costs no round trip of its own. Runs on the relay queue, off the cooperative pool.
    func openFirstChannel(destination: SSHForwardDestination) async throws {
        guard session.addDeathHandler(id: leaseId, { [weak self] in self?.sessionDied() }) else {
            throw SSHTunnelError.tunnelCreationFailed("The SSH connection closed")
        }
        let deadline = connectionDeadline
        let endpoint = ConnectionTimeoutEndpoint.tunnel(destination.logDescription)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<OpenOutcome, Never>) in
                relayQueue.async { [self] in
                    let outcome = session.openChannel(
                        destination: destination,
                        originPort: localPort,
                        deadline: deadline,
                        isActive: { [weak self] in
                            (self?.aliveLatch.isLive ?? false) && !cancelled.withLock { $0 }
                        }
                    )
                    continuation.resume(returning: OpenOutcome(value: outcome))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }

        switch outcome.value {
        case .opened(let channel):
            guard firstChannel.hold(channel) else {
                let late = OpenOutcome(value: .opened(channel))
                relayQueue.async { [session] in
                    if case .opened(let channel) = late.value { session.freeChannel(channel) }
                }
                throw SSHTunnelError.tunnelCreationFailed("The SSH connection closed")
            }
            // A client that never comes would leave the destination's connection open until the tunnel closes.
            let window = SSHChannelHandOff.defaultWindow.components
            let windowSeconds = Double(window.seconds) + Double(window.attoseconds) / 1e18
            relayQueue.asyncAfter(deadline: .now() + windowSeconds) { [weak self] in
                self?.dropHeldChannel()
            }
            return
        case .cancelled where cancelled.withLock({ $0 }):
            throw CancellationError()
        case _ where deadline.isExpired:
            throw deadline.timeoutError(for: endpoint)
        case .cancelled:
            throw SSHTunnelError.tunnelCreationFailed("The SSH connection closed")
        case .failed, .timedOut:
            let error = outcome.value.forwardFailure(
                destination: destination,
                deadlineSeconds: deadline.configuredSeconds
            )?.tunnelError ?? SSHTunnelError.channelOpenFailed
            Self.logger.error("Forward probe to \(destination.logDescription) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private struct OpenOutcome: @unchecked Sendable {
        let value: ChannelOpenOutcome
    }

    // MARK: - Forwarding

    func startForwarding(destination: SSHForwardDestination) {
        // A handler already running when the latch is claimed may still spawn one client; teardown waits for the
        // cancel handler before the client group, so it waits for that client too.
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
        let started = self.acceptor.withLock { slot -> Bool in
            guard aliveLatch.isLive else { return false }
            slot = acceptor
            return true
        }
        guard started else {
            acceptor.cancel()
            return
        }
        acceptor.start()
        Self.logger.info("Forwarding started on port \(self.localPort) -> \(destination.logDescription)")
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

    // MARK: - Lifecycle

    func close() {
        guard aliveLatch.claim() else { return }
        performTeardown()
    }

    // The shared session died; every tunnel on it starts its own connection's recovery.
    private func sessionDied() {
        guard aliveLatch.claim() else { return }
        performTeardown()
        onDeath(self)
    }

    // The listening socket closes only after the acceptor's cancel handler ran, which GCD runs once no accept
    // handler is running. The clients are awaited after that, because the accept handler is the only thing that
    // starts one: the group can only empty. The lease goes back last, so the session outlives every use of it here.
    private func performTeardown() {
        let acceptor = self.acceptor.withLock { $0 }
        acceptor?.cancel()
        session.removeDeathHandler(id: leaseId)
        let relayIds = relays.withLock { relays -> [SSHSessionPump.RelayID] in
            relays.isClosing = true
            return Array(relays.ids.values)
        }
        relayIds.forEach { session.endRelay($0) }

        let session = self.session
        let clients = self.clients
        let relayQueue = self.relayQueue
        let listenFD = self.listenFD
        let releaseLease = self.releaseLease
        let connectionId = self.connectionId
        let firstChannel = self.firstChannel
        Task.detached {
            await acceptor?.waitForCancellation()
            Darwin.close(listenFD)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                relayQueue.async {
                    if let channel = firstChannel.close() {
                        session.freeChannel(channel)
                    }
                    clients.notify(queue: relayQueue) { continuation.resume() }
                }
            }
            releaseLease()
            Self.logger.info("Tunnel closed for connection \(connectionId)")
        }
    }

    // App termination: waits for nothing and frees nothing, since the OS reclaims it all.
    func closeSync() {
        guard aliveLatch.claim() else { return }
        acceptor.withLock { $0 }?.cancel()
        let relayIds = relays.withLock { relays -> [SSHSessionPump.RelayID] in
            relays.isClosing = true
            return Array(relays.ids.values)
        }
        relayIds.forEach { session.endRelay($0) }
    }

    // MARK: - Clients

    // On `relayQueue`, off the accept handler, so a slow open cannot delay the next accept. The client stays in
    // `clients` until its relay ended.
    private func spawnClient(
        clientFD: Int32,
        budget: ConnectionRelayDeadlineProvider.Budget,
        destination: SSHForwardDestination
    ) {
        let clients = self.clients
        clients.enter()
        relayQueue.async { [weak self] in
            guard let self else {
                Darwin.close(clientFD)
                clients.leave()
                return
            }
            self.openAndRelay(clientFD: clientFD, budget: budget, destination: destination)
        }
    }

    private func dropHeldChannel() {
        switch firstChannel.take() {
        case .fresh(let channel), .stale(let channel):
            session.freeChannel(channel)
        case .none:
            break
        }
    }

    // Off the session queue between open attempts, so a slow open cannot stall the relays and the keep-alive that
    // share the session.
    private func openAndRelay(
        clientFD: Int32,
        budget: ConnectionRelayDeadlineProvider.Budget,
        destination: SSHForwardDestination
    ) {
        switch firstChannel.take() {
        case .fresh(let channel):
            relayChannel(clientFD: clientFD, channel: channel, destination: destination)
            return
        case .stale(let channel):
            session.freeChannel(channel)
        case .none:
            break
        }

        let connectionDeadline = budget.deadline
        let outcome = session.openChannel(
            destination: destination,
            originPort: localPort,
            deadline: connectionDeadline,
            isActive: { [weak self] in self?.aliveLatch.isLive ?? false }
        )
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
                    $0 = connectionDeadline.timeoutError(for: session.timeoutEndpoint)
                }
            }
            if case .opened(let channel) = outcome {
                Darwin.close(clientFD)
                session.freeChannel(channel)
                clients.leave()
                return
            }
        }
        let deadlineSeconds = connectionDeadline.configuredSeconds
        logChannelOpenOutcome(outcome, destination: destination, deadlineSeconds: deadlineSeconds)
        forwardFailure.record(outcome, destination: destination, deadlineSeconds: deadlineSeconds)
        handleChannelOpenOutcome(outcome, clientFD: clientFD) { channel in
            relayChannel(clientFD: clientFD, channel: channel, destination: destination)
        }
        if case .opened = outcome { return }
        clients.leave()
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

    // Every termination is logged, not just a hangup: a channel that opens only after the database
    // client already gave up ends as `.localClosed`, and staying silent about that leaves no trace
    // of a tunnel that worked but arrived too late.
    private func relayChannel(clientFD: Int32, channel: OpaquePointer, destination: SSHForwardDestination) {
        let startedAt = Date()
        let target = destination.logDescription
        let clients = self.clients
        let relays = self.relays
        let token = UUID()
        relays.withLock { _ = $0.running.insert(token) }
        let id = session.relay(clientFD: clientFD, channel: channel, byteCounter: byteCounter) { termination in
            relays.withLock { relays in
                relays.running.remove(token)
                relays.ids[token] = nil
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            Self.logger.debug(
                "Relay to \(target) ended as \(String(describing: termination)) after \(elapsed, format: .fixed(precision: 1))s"
            )
            clients.leave()
        }
        // Recorded once the pump named it, so a close in between still ends it; one already ended is not kept.
        let closing = relays.withLock { relays -> Bool in
            guard relays.running.contains(token) else { return false }
            relays.ids[token] = id
            return relays.isClosing
        }
        if closing { session.endRelay(id) }
    }
}
