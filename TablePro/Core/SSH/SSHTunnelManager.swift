//
//  SSHTunnelManager.swift
//  TablePro
//
//  Manages SSH tunnel lifecycle for database connections using libssh2
//

import Foundation
import os

/// Why an SSH authentication attempt failed. Drives the user-facing error string so the
/// alert points at the actual cause (wrong OTP, missing key, agent rejection) instead of
/// the catch-all "credentials or private key" message.
enum AuthFailureReason: Sendable, Hashable, CaseIterable {
    case password
    case verificationCode
    case privateKey
    case agentUnavailable(AgentSocketOrigin)
    case agentNoIdentities(AgentSocketOrigin)
    case agentRejected
    case passwordlessRejected
    case keyboardInteractive
    case methodUnavailable
    case cancelled
    case generic

    /// Hand-written because the two agent cases carry the socket source they are about, which
    /// stops `CaseIterable` synthesising this.
    static var allCases: [AuthFailureReason] {
        [.password, .verificationCode, .privateKey]
            + AgentSocketOrigin.allCases.map(AuthFailureReason.agentUnavailable)
            + AgentSocketOrigin.allCases.map(AuthFailureReason.agentNoIdentities)
            + [.agentRejected, .passwordlessRejected, .keyboardInteractive, .methodUnavailable,
               .cancelled, .generic]
    }
}

extension AuthFailureReason {
    /// True when the step never exchanged a credential with the server, so its failure says
    /// nothing about why authentication was refused. `CompositeAuthenticator` keeps an earlier,
    /// real failure rather than letting one of these displace it.
    var describesAnAttempt: Bool {
        self != .methodUnavailable
    }
}

private extension AgentSocketOrigin {
    /// Names the socket the connect actually used, and the one place that names it. A jump hop
    /// has no Agent Socket control of its own, and a shell-launched app can inherit an
    /// `SSH_AUTH_SOCK` that is not the agent macOS runs, so neither can be assumed.
    var whereTheSocketCameFrom: String {
        switch self {
        case .agentSocketSetting:
            return String(localized: "the Agent Socket setting")
        case .identityAgentDirective:
            return String(localized: "the IdentityAgent line for this host in ~/.ssh/config")
        case .environment:
            return String(localized: "SSH_AUTH_SOCK")
        }
    }

    /// How to put a key in front of that particular agent.
    var howToLoadAKey: String {
        switch self {
        case .agentSocketSetting, .identityAgentDirective:
            return String(localized: "Unlock the app that runs it and add the key there.")
        case .environment:
            return String(localized: "Run ssh-add to load one, or point Agent Socket at another agent.")
        }
    }
}

/// Error types for SSH tunnel operations
enum SSHTunnelError: Error, LocalizedError, Equatable, Sendable {
    case tunnelCreationFailed(String)
    case tunnelAlreadyExists(UUID)
    case noAvailablePort
    case authenticationFailed(reason: AuthFailureReason)
    case connectionTimeout
    case hostKeyVerificationFailed
    case channelOpenFailed
    case socketForwardingRefused(path: String, detail: String)
    case forwardRefused(destination: String, detail: String)
    case forwardTimedOut(destination: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .tunnelCreationFailed(let message):
            return String(format: String(localized: "SSH tunnel creation failed: %@"), message)
        case .tunnelAlreadyExists(let id):
            return String(format: String(localized: "SSH tunnel already exists for connection: %@"), id.uuidString)
        case .noAvailablePort:
            return String(localized: "No available local port for SSH tunnel")
        case .authenticationFailed(let reason):
            switch reason {
            case .password:
                return String(localized: "SSH password rejected. Check the password and try again.")
            case .verificationCode:
                return String(localized: "Verification code rejected. Get a new code from your authenticator app and try again.")
            case .privateKey:
                return String(localized: "SSH private key rejected. Check the key file or passphrase.")
            case .agentUnavailable(let origin):
                return String(
                    format: String(localized: "No SSH agent answered on the socket from %@. Check that agent is running."),
                    origin.whereTheSocketCameFrom
                )
            case .agentNoIdentities(let origin):
                return String(
                    format: String(localized: "The SSH agent from %@ holds no keys. %@"),
                    origin.whereTheSocketCameFrom,
                    origin.howToLoadAKey
                )
            case .agentRejected:
                return String(localized: "SSH agent did not authenticate. Run ssh-add -l to check loaded keys.")
            case .passwordlessRejected:
                return String(localized: "The SSH server did not accept passwordless authentication. Choose Password, Private Key, or SSH Agent.")
            case .keyboardInteractive:
                return String(localized: "SSH verification rejected. Check your response and try again.")
            case .methodUnavailable:
                return String(localized: "The SSH server does not offer that authentication method.")
            case .cancelled:
                return String(localized: "SSH authentication cancelled.")
            case .generic:
                return String(localized: "SSH authentication failed. Check your credentials or private key.")
            }
        case .connectionTimeout:
            return String(localized: "SSH connection timed out")
        case .hostKeyVerificationFailed:
            return String(localized: "SSH host key verification failed")
        case .channelOpenFailed:
            return String(localized: "Failed to open SSH channel for port forwarding")
        case .socketForwardingRefused(let path, let detail):
            return String(
                format: String(
                    localized: """
                    The SSH server would not forward the socket %@. Check that the path exists on the server \
                    and that sshd allows socket forwarding (AllowStreamLocalForwarding). (%@)
                    """
                ),
                path,
                detail
            )
        case .forwardRefused(let destination, let detail):
            return String(
                format: String(
                    localized: """
                    The SSH server could not reach %@. That address is resolved from the SSH server, not from \
                    your Mac, so a database that only listens on 127.0.0.1 needs Host set to localhost. Also \
                    check that sshd allows TCP forwarding (AllowTcpForwarding). (%@)
                    """
                ),
                destination,
                detail
            )
        case .forwardTimedOut(let destination, let seconds):
            return String(
                format: String(
                    localized: """
                    The SSH server did not open a forwarding channel to %@ within %d seconds. Check for a \
                    firewall between the SSH server and that address.
                    """
                ),
                destination,
                seconds
            )
        }
    }
}

extension SSHTunnelError {
    var isUserCancelledAuthentication: Bool {
        guard case .authenticationFailed(reason: .cancelled) = self else { return false }
        return true
    }
}

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
        totpPeriod: Int = 30
    ) async throws -> Int {
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
            do {
                let tunnel = try await Task.detached {
                    try await LibSSH2TunnelFactory.createTunnel(
                        connectionId: connectionId,
                        config: config,
                        credentials: credentials,
                        destination: destination,
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

    /// The reason this tunnel last failed to open a forwarding channel, cleared as it is read.
    /// The connect path reports it in place of the database driver's error, which can only ever
    /// name a timeout because the driver sees an accepted socket that stayed silent.
    func consumeLastForwardFailure(connectionId: UUID) -> SSHTunnelError? {
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
