//
//  RemoteSQLiteTransportManager.swift
//  TablePro
//

import Foundation
import os

/// The loopback endpoint a remote SQLite connection's driver dials, and the token that admits it.
struct RemoteSQLiteEndpoint: Sendable {
    let port: Int
    let token: String
}

/// Owns one `RemoteSQLiteTunnel` per connection, so disconnect, health checks and the
/// mutual-exclusivity rule reach a live remote SQLite session the way they reach every other
/// transport.
actor RemoteSQLiteTransportManager: TunnelManaging {
    static let shared = RemoteSQLiteTransportManager()

    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteSQLiteTransport")
    private static let portRangeStart = 60_000
    private static let portRangeEnd = 65_000

    private var tunnels: [UUID: RemoteSQLiteTunnel] = [:]
    private static let tunnelRegistry = OSAllocatedUnfairLock(initialState: [UUID: RemoteSQLiteTunnel]())
    private var appNapActivity: NSObjectProtocol?

    private init() {}

    func createTunnel(
        connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) async throws -> RemoteSQLiteEndpoint {
        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        let token = RemoteSQLiteAdmission.newToken()
        let command = RemoteSQLiteAgentSource.launcherCommand()
        let candidatePorts = localPortCandidates()

        /// The tunnel is built inside the detached task and only it, not the authenticated chain of
        /// raw libssh2 handles it holds, crosses back to the actor. That is what `LibSSH2Tunnel`'s
        /// factory does too, and it is what keeps the non-Sendable session out of an actor hop.
        let tunnel = try await Task.detached {
            let chain = try await LibSSH2TunnelFactory.buildAuthenticatedChain(
                config: config,
                credentials: credentials,
                queueLabel: "com.TablePro.rsqlite.hop.\(connectionId.uuidString)"
            )
            for port in candidatePorts {
                if let listenFD = Self.bindLoopbackListener(port: port) {
                    return RemoteSQLiteTunnel(
                        connectionId: connectionId,
                        localPort: port,
                        chain: chain,
                        listenFD: listenFD,
                        command: command,
                        token: token
                    )
                }
            }
            LibSSH2TunnelFactory.cleanupChain(chain, reason: "no local port")
            throw SSHTunnelError.noAvailablePort
        }.value

        tunnel.onDeath = { [weak self] id in
            Task { [weak self] in await self?.handleTunnelDeath(connectionId: id) }
        }

        tunnels[connectionId] = tunnel
        Self.tunnelRegistry.withLock { $0[connectionId] = tunnel }
        tunnel.startForwarding()
        tunnel.startKeepAlive()
        updateAppNapState()

        Self.logger.info("Remote SQLite session ready for \(connectionId) on 127.0.0.1:\(tunnel.localPort)")
        return RemoteSQLiteEndpoint(port: tunnel.localPort, token: token)
    }

    func closeTunnel(connectionId: UUID) async throws {
        guard let tunnel = tunnels.removeValue(forKey: connectionId) else { return }
        Self.tunnelRegistry.withLock { $0[connectionId] = nil }
        updateAppNapState()
        tunnel.close()
    }

    func hasTunnel(connectionId: UUID) -> Bool {
        guard let tunnel = tunnels[connectionId] else { return false }
        return tunnel.isRunning
    }

    func getLocalPort(connectionId: UUID) -> Int? {
        guard let tunnel = tunnels[connectionId], tunnel.isRunning else { return nil }
        return tunnel.localPort
    }

    nonisolated func terminateAllProcessesSync() {
        let tunnelsToClose = Self.tunnelRegistry.withLock { dict -> [RemoteSQLiteTunnel] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for tunnel in tunnelsToClose { tunnel.closeSync() }
    }

    // MARK: - Private

    private func handleTunnelDeath(connectionId: UUID) async {
        guard tunnels.removeValue(forKey: connectionId) != nil else { return }
        Self.tunnelRegistry.withLock { $0[connectionId] = nil }
        updateAppNapState()
        Self.logger.warning("Remote SQLite session died for \(connectionId)")
        await DatabaseManager.shared.handleRemoteSQLiteTunnelDied(connectionId: connectionId)
    }

    private func localPortCandidates() -> [Int] {
        Array(Self.portRangeStart...Self.portRangeEnd).shuffled()
    }

    private static func bindLoopbackListener(port: Int) -> Int32? {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return nil }

        var reuseAddr: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else {
            Darwin.close(listenFD)
            return nil
        }
        return listenFD
    }

    private func updateAppNapState() {
        if !tunnels.isEmpty && appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Remote SQLite session keepalive requires timely execution"
            )
        } else if tunnels.isEmpty, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }
}
