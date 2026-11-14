//
//  SSHTunnelManager.swift
//  TablePro
//
//  Manages SSH tunnel lifecycle for database connections using libssh2
//

import Foundation
import os

import TableProSSHConfig
import TableProSSHTransport

/// Manages SSH tunnels for database connections using libssh2
actor SSHTunnelManager: TunnelManaging {
    static let shared = SSHTunnelManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnelManager")

    private var tunnels: [UUID: LibSSH2Tunnel] = [:]
    private var creations = TunnelCreationGenerations()
    private let localPortCandidates: @Sendable () -> [Int]

    /// Static registry for synchronous termination during app shutdown
    private static let tunnelRegistry = OSAllocatedUnfairLock(initialState: [UUID: LibSSH2Tunnel]())

    init(localPortCandidates: @escaping @Sendable () -> [Int] = { Array(60_000...65_000).shuffled() }) {
        self.localPortCandidates = localPortCandidates
    }

    func createTunnel(
        connectionId: UUID,
        sshHost: String,
        sshPort: Int? = nil,
        sshUsername: String,
        authMethod: SSHAuthMethod,
        privateKeyPath: String? = nil,
        keyPassphrase: String? = nil,
        sshPassword: String? = nil,
        agentSocketPath: String? = nil,
        destination: SSHForwardDestination,
        jumpHosts: [SSHJumpHost] = [],
        totpMode: TOTPMode = .none,
        totpSecret: String? = nil,
        totpAlgorithm: TOTPAlgorithm = .sha1,
        totpDigits: Int = 6,
        totpPeriod: Int = 30,
        deadline: ConnectionDeadline = ConnectionDeadline(configuredSeconds: nil)
    ) async throws -> Int {
        let generation = creations.begin(connectionId)
        defer { creations.finish(generation, for: connectionId) }
        let timeoutEndpoint = ConnectionTimeoutEndpoint.tunnel("\(sshHost):\(sshPort ?? 22)")
        try deadline.check(endpoint: timeoutEndpoint)
        if tunnels[connectionId] != nil {
            try await discardTunnel(connectionId: connectionId)
        }

        let config = SSHConfiguration(
            enabled: true,
            host: sshHost,
            port: sshPort,
            username: sshUsername,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath ?? "",
            agentSocketPath: agentSocketPath ?? "",
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        let credentials = SSHTunnelCredentials(
            sshPassword: sshPassword,
            keyPassphrase: keyPassphrase,
            totpSecret: totpSecret,
            keyboardInteractivePromptProvider: nil
        )

        try deadline.check(endpoint: timeoutEndpoint)
        let listener = try LibSSH2TunnelFactory.bindLocalListener(candidates: localPortCandidates())
        let creationTask = Task.detached {
            try await LibSSH2TunnelFactory.createTunnel(
                connectionId: connectionId,
                config: config,
                credentials: credentials,
                destination: destination,
                listener: listener,
                deadline: deadline
            )
        }
        let tunnel = try await withTaskCancellationHandler {
            try await creationTask.value
        } onCancel: {
            creationTask.cancel()
        }

        do {
            try deadline.check(endpoint: timeoutEndpoint)
        } catch {
            tunnel.close()
            throw error
        }
        // A newer createTunnel or a close for this connection came while this one dialed, so it must not adopt.
        guard creations.isNewest(generation, for: connectionId) else {
            tunnel.close()
            throw CancellationError()
        }

        tunnel.onDeath = { [weak self] id in
            Task { [weak self] in
                await self?.handleTunnelDeath(connectionId: id)
            }
        }

        tunnels[connectionId] = tunnel
        Self.tunnelRegistry.withLock { $0[connectionId] = tunnel }

        tunnel.startForwarding(destination: destination)
        tunnel.startKeepAlive()

        Self.logger.info("Tunnel created for \(connectionId) on local port \(listener.port)")
        return listener.port
    }

    // Also ends a creation still dialing, so nothing it builds is adopted after the close returned.
    func closeTunnel(connectionId: UUID) async throws {
        creations.invalidate(connectionId)
        try await discardTunnel(connectionId: connectionId)
    }

    private func discardTunnel(connectionId: UUID) async throws {
        guard let tunnel = tunnels.removeValue(forKey: connectionId) else { return }
        Self.tunnelRegistry.withLock { $0[connectionId] = nil }
        tunnel.close()
    }

    func closeAllTunnels() async {
        creations.invalidateAll()
        let currentTunnels = tunnels
        tunnels.removeAll()
        Self.tunnelRegistry.withLock { $0.removeAll(); return }

        for (_, tunnel) in currentTunnels {
            tunnel.close()
        }
    }

    /// Synchronously terminate all SSH tunnel processes.
    /// Called from `applicationWillTerminate` where async is not available.
    nonisolated func terminateAllProcessesSync() {
        let tunnelsToClose = Self.tunnelRegistry.withLock { dict -> [LibSSH2Tunnel] in
            let tunnels = Array(dict.values)
            dict.removeAll()
            return tunnels
        }
        for tunnel in tunnelsToClose {
            tunnel.closeSync()
        }
    }

    /// Test SSH connectivity without creating a tunnel.
    func testSSHProfile(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        deadline: ConnectionDeadline = ConnectionDeadline(configuredSeconds: nil)
    ) async throws {
        let testTask = Task.detached {
            try await LibSSH2TunnelFactory.testConnection(
                config: config,
                credentials: credentials,
                deadline: deadline
            )
        }
        try await withTaskCancellationHandler {
            try await testTask.value
        } onCancel: {
            testTask.cancel()
        }
    }

    /// Check if a tunnel exists for a connection
    func hasTunnel(connectionId: UUID) -> Bool {
        guard let tunnel = tunnels[connectionId] else { return false }
        return tunnel.isRunning
    }

    /// Get the local port for an existing tunnel
    func dialedRoute(connectionId: UUID) -> DialedSSHRoute? {
        tunnels[connectionId]?.dialedRoute
    }

    func getLocalPort(connectionId: UUID) -> Int? {
        guard let tunnel = tunnels[connectionId], tunnel.isRunning else {
            return nil
        }
        return tunnel.localPort
    }

    /// The reason this tunnel last failed to open a forwarding channel, cleared as it is read.
    /// The connect path reports it in place of the database driver's error, which can only ever
    /// name a timeout because the driver sees an accepted socket that stayed silent.
    func consumeLastForwardFailure(connectionId: UUID) -> (any Error)? {
        tunnels[connectionId]?.consumeLastForwardFailure()
    }

    // MARK: - Private

    private func handleTunnelDeath(connectionId: UUID) async {
        guard tunnels.removeValue(forKey: connectionId) != nil else { return }
        Self.tunnelRegistry.withLock { $0[connectionId] = nil }
        Self.logger.warning("Tunnel died for connection \(connectionId)")
        await DatabaseManager.shared.handleSSHTunnelDied(connectionId: connectionId)
    }
}
