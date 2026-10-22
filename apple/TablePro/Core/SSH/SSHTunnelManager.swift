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
    private let portRangeStart = 60_000
    private let portRangeEnd = 65_000

    /// Static registry for synchronous termination during app shutdown
    private static let tunnelRegistry = OSAllocatedUnfairLock(initialState: [UUID: LibSSH2Tunnel]())

    /// Prevents App Nap from throttling SSH keepalive timers while tunnels are active.
    /// Held as long as at least one tunnel exists; released when the last tunnel closes.
    private var appNapActivity: NSObjectProtocol?

    private init() {}

    /// Create an SSH tunnel for a database connection.
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
        let timeoutEndpoint = ConnectionTimeoutEndpoint.tunnel("\(sshHost):\(sshPort ?? 22)")
        try deadline.check(endpoint: timeoutEndpoint)
        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
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

        // Try ports until one works
        for localPort in localPortCandidates() {
            try deadline.check(endpoint: timeoutEndpoint)
            do {
                let creationTask = Task.detached {
                    try await LibSSH2TunnelFactory.createTunnel(
                        connectionId: connectionId,
                        config: config,
                        credentials: credentials,
                        destination: destination,
                        localPort: localPort,
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

                tunnel.onDeath = { [weak self] id in
                    Task { [weak self] in
                        await self?.handleTunnelDeath(connectionId: id)
                    }
                }

                tunnels[connectionId] = tunnel
                Self.tunnelRegistry.withLock { $0[connectionId] = tunnel }

                tunnel.startForwarding(destination: destination)
                tunnel.startKeepAlive()

                updateAppNapState()
                Self.logger.info("Tunnel created for \(connectionId) on local port \(localPort)")
                return localPort
            } catch let error as SSHTunnelError {
                if case .tunnelCreationFailed(let msg) = error,
                   msg.contains("already in use") {
                    Self.logger.notice("Port \(localPort) in use, trying another")
                    continue
                }
                throw error
            }
        }

        throw SSHTunnelError.noAvailablePort
    }

    /// Close an SSH tunnel
    func closeTunnel(connectionId: UUID) async throws {
        guard let tunnel = tunnels.removeValue(forKey: connectionId) else { return }
        Self.tunnelRegistry.withLock { $0[connectionId] = nil }
        updateAppNapState()
        tunnel.close()
    }

    /// Close all SSH tunnels
    func closeAllTunnels() async {
        let currentTunnels = tunnels
        tunnels.removeAll()
        Self.tunnelRegistry.withLock { $0.removeAll(); return }
        updateAppNapState()

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

    /// Check if an error message indicates a local port bind failure
    static func isLocalPortBindFailure(_ errorMessage: String) -> Bool {
        errorMessage.lowercased().contains("already in use")
    }

    // MARK: - Private

    private func localPortCandidates() -> [Int] {
        Array(portRangeStart...portRangeEnd).shuffled()
    }

    private func handleTunnelDeath(connectionId: UUID) async {
        guard tunnels.removeValue(forKey: connectionId) != nil else { return }
        Self.tunnelRegistry.withLock { $0[connectionId] = nil }
        updateAppNapState()
        Self.logger.warning("Tunnel died for connection \(connectionId)")
        await DatabaseManager.shared.handleSSHTunnelDied(connectionId: connectionId)
    }

    // MARK: - App Nap Prevention

    /// Acquires or releases an App Nap activity token based on whether tunnels exist.
    private func updateAppNapState() {
        if !tunnels.isEmpty && appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "SSH tunnel keepalive requires timely execution"
            )
            Self.logger.debug("App Nap prevention acquired")
        } else if tunnels.isEmpty, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
            Self.logger.debug("App Nap prevention released")
        }
    }
}
