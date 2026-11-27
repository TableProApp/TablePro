//
//  DatabaseManager+NetworkPath.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProUtilities

// MARK: - Network path

extension DatabaseManager {
    internal var isNetworkPathSatisfied: Bool {
        networkPath?.isSatisfied ?? true
    }

    internal func startObservingNetworkPath() {
        guard networkMonitor == nil else { return }
        let monitor = ConnectionNetworkMonitor()
        networkMonitor = monitor
        monitor.start { [weak self] snapshot in
            self?.networkPathChanged(to: snapshot)
        }
    }

    /// A path that came back, or moved to other interfaces, wakes every waiting recovery loop so each retries at
    /// once, and checks every live session: a socket that crossed the outage can be dead without having said so.
    internal func networkPathChanged(to snapshot: NetworkPathSnapshot) {
        let previous = networkPath
        networkPath = snapshot
        guard let previous, snapshot.isSatisfied else { return }
        guard !previous.isSatisfied || previous.interfaces != snapshot.interfaces else { return }
        Self.logger.info("Network path is back or changed, retrying reconnects and checking sessions")
        wakeNetworkChangeWaiters()
        Task { [weak self] in
            guard let self else { return }
            self.forgetAllVerifications()
            await self.validateTunneledSessions()
            await self.verifyLiveSessions()
        }
    }

    /// Returns when the path next comes back or changes interface, or throws once the caller is cancelled.
    internal func waitForNetworkChange() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                networkChangeWaiters[token] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.networkChangeWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Whether the connection needs the network path. Only one that provably stays on this Mac answers no: a local
    /// socket, or a plain network engine whose Host field names loopback, answers with Wi-Fi and Ethernet both off,
    /// and its loop must keep dialing. A tunnel, an empty Host (a host list or a seed field) or an engine that
    /// reads its address from its own fields may leave the Mac, so it waits for the path.
    internal func dialsThroughNetwork(_ connectionId: UUID) -> Bool {
        guard let connection = activeSessions[connectionId]?.connection else { return true }
        if connection.activeTunnelKind != nil { return true }
        if connection.localSocketPath != nil { return false }
        guard PluginMetadataRegistry.shared.snapshot(for: connection.type)?.connectionMode == .network else { return true }
        return !LoopbackHost.isLoopback(connection.host)
    }

    /// Sleeps out a retry delay, cut short when the network comes back: the backoff is for a server that refuses,
    /// not for a path that was down.
    internal func waitBeforeRetry(_ delay: TimeInterval) async throws {
        let clock = recoveryClock
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await clock.sleep(for: .seconds(delay)) }
            group.addTask { try await self.waitForNetworkChange() }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func wakeNetworkChangeWaiters() {
        let waiters = networkChangeWaiters
        networkChangeWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Asks every live session the check a use would, at once: direct sessions too, which a tunnel check skips.
    internal func verifyLiveSessions() async {
        let live = activeSessions.filter { $0.value.isConnected && $0.value.liveness == .live }.map(\.key)
        await withTaskGroup(of: Void.self) { group in
            for connectionId in live {
                group.addTask { await self.verifyBeforeUse(connectionId) }
            }
        }
    }
}
