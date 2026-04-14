//
//  SSHTunnelManager.swift
//  TablePro
//
//  Manages SSH tunnel lifecycle for database connections using libssh2
//

import Foundation
import os

/// Error types for SSH tunnel operations
enum SSHTunnelError: Error, LocalizedError {
    case tunnelCreationFailed(String)
    case tunnelAlreadyExists(UUID)
    case noAvailablePort
    case authenticationFailed
    case connectionTimeout
    case hostKeyVerificationFailed
    case channelOpenFailed

    var errorDescription: String? {
        switch self {
        case .tunnelCreationFailed(let message):
            return String(format: String(localized: "SSH tunnel creation failed: %@"), message)
        case .tunnelAlreadyExists(let id):
            return String(format: String(localized: "SSH tunnel already exists for connection: %@"), id.uuidString)
        case .noAvailablePort:
            return String(localized: "No available local port for SSH tunnel")
        case .authenticationFailed:
            return String(localized: "SSH authentication failed. Check your credentials or private key.")
        case .connectionTimeout:
            return String(localized: "SSH connection timed out")
        case .hostKeyVerificationFailed:
            return String(localized: "SSH host key verification failed")
        case .channelOpenFailed:
            return String(localized: "Failed to open SSH channel for port forwarding")
        }
    }
}

/// Manages SSH tunnels for database connections using libssh2
actor SSHTunnelManager {
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
        sshPort: Int = 22,
        sshUsername: String,
        authMethod: SSHAuthMethod,
        privateKeyPath: String? = nil,
        keyPassphrase: String? = nil,
        sshPassword: String? = nil,
        agentSocketPath: String? = nil,
        remoteHost: String,
        remotePort: Int,
        jumpHosts: [SSHJumpHost] = [],
        totpMode: TOTPMode = .none,
        totpSecret: String? = nil,
        totpAlgorithm: TOTPAlgorithm = .sha1,
        totpDigits: Int = 6,
        totpPeriod: Int = 30
    ) async throws -> Int {
        // Close existing tunnel if any
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
            totpProvider: nil
        )

        // Try ports until one works
        for localPort in localPortCandidates() {
            do {
                let tunnel = try await Task.detached {
                    try await LibSSH2TunnelFactory.createTunnel(
                        connectionId: connectionId,
                        config: config,
                        credentials: credentials,
                        remoteHost: remoteHost,
                        remotePort: remotePort,
                        localPort: localPort
                    )
                }.value

                tunnel.onDeath = { [weak self] id in
                    Task { [weak self] in
                        await self?.handleTunnelDeath(connectionId: id)
                    }
                }

                tunnels[connectionId] = tunnel
                Self.tunnelRegistry.withLock { $0[connectionId] = tunnel }

                tunnel.startForwarding(remoteHost: remoteHost, remotePort: remotePort)
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
        credentials: SSHTunnelCredentials
    ) async throws {
        try await Task.detached {
            try await LibSSH2TunnelFactory.testConnection(
                config: config,
                credentials: credentials
            )
        }.value
    }

    /// Check if a tunnel exists for a connection
    func hasTunnel(connectionId: UUID) -> Bool {
        guard let tunnel = tunnels[connectionId] else { return false }
        return tunnel.isRunning
    }

    /// Get the local port for an existing tunnel
    func getLocalPort(connectionId: UUID) -> Int? {
        guard let tunnel = tunnels[connectionId], tunnel.isRunning else {
            return nil
        }
        return tunnel.localPort
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
