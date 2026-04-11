//
//  SSHTunnelFormState.swift
//  TablePro
//

import Foundation

/// Encapsulates all SSH tunnel UI state for the connection form.
/// Replaces the 23 scattered @State variables in ConnectionFormView.
struct SSHTunnelFormState {
    // Mode
    var enabled: Bool = false
    var profileId: UUID?
    var profiles: [SSHProfile] = []

    // Sheet presentation
    var showingCreateProfile: Bool = false
    var editingProfile: SSHProfile?
    var showingSaveAsProfile: Bool = false

    // Inline config fields
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var password: String = ""
    var authMethod: SSHAuthMethod = .password
    var privateKeyPath: String = ""
    var agentSocketOption: SSHAgentSocketOption = .systemDefault
    var customAgentSocketPath: String = ""
    var keyPassphrase: String = ""
    var configEntries: [SSHConfigEntry] = []
    var selectedConfigHost: String = ""
    var jumpHosts: [SSHJumpHost] = []
    var totpMode: TOTPMode = .none
    var totpSecret: String = ""
    var totpAlgorithm: TOTPAlgorithm = .sha1
    var totpDigits: Int = 6
    var totpPeriod: Int = 30

    // MARK: - Computed Properties

    var selectedProfile: SSHProfile? {
        guard let id = profileId else { return nil }
        return profiles.first { $0.id == id }
    }

    var resolvedAgentSocketPath: String {
        agentSocketOption.resolvedPath(customPath: customAgentSocketPath)
    }

    // MARK: - Build Methods

    func buildInlineConfig() -> SSHConfiguration {
        SSHConfiguration(
            enabled: enabled,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            useSSHConfig: !selectedConfigHost.isEmpty,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )
    }

    func buildSSHConfig() -> SSHConfiguration {
        if let profileId, let profile = profiles.first(where: { $0.id == profileId }) {
            return profile.toSSHConfiguration()
        }
        return buildInlineConfig()
    }

    // MARK: - Load Methods

    mutating func load(from connection: DatabaseConnection) {
        switch connection.sshTunnelMode {
        case .disabled:
            enabled = false
            profileId = nil
        case .inline(let config):
            enabled = true
            profileId = nil
            populateFields(from: config)
        case .profile(let id, let snapshot):
            enabled = true
            profileId = id
            populateFields(from: snapshot)
        }
    }

    @MainActor
    mutating func loadSecrets(connectionId: UUID, storage: ConnectionStorage) {
        if case .profile(let profileId, _) = buildTunnelMode() {
            // Profile-mode: load secrets from profile keychain namespace
            password = SSHProfileStorage.shared.loadSSHPassword(for: profileId) ?? ""
            keyPassphrase = SSHProfileStorage.shared.loadKeyPassphrase(for: profileId) ?? ""
            totpSecret = SSHProfileStorage.shared.loadTOTPSecret(for: profileId) ?? ""
        } else {
            // Inline/disabled: load from connection keychain namespace
            password = storage.loadSSHPassword(for: connectionId) ?? ""
            keyPassphrase = storage.loadKeyPassphrase(for: connectionId) ?? ""
            totpSecret = storage.loadTOTPSecret(for: connectionId) ?? ""
        }
    }

    /// Build the SSHTunnelMode for saving to the connection.
    func buildTunnelMode() -> SSHTunnelMode {
        guard enabled else { return .disabled }
        if let profileId, let profile = profiles.first(where: { $0.id == profileId }) {
            return .profile(id: profileId, snapshot: profile.toSSHConfiguration())
        }
        return .inline(buildInlineConfig())
    }

    // MARK: - Mutation Methods

    mutating func disable() {
        enabled = false
        profileId = nil
        host = ""
        port = "22"
        username = ""
        password = ""
        authMethod = .password
        privateKeyPath = ""
        agentSocketOption = .systemDefault
        customAgentSocketPath = ""
        keyPassphrase = ""
        selectedConfigHost = ""
        jumpHosts = []
        totpMode = .none
        totpSecret = ""
        totpAlgorithm = .sha1
        totpDigits = 6
        totpPeriod = 30
    }

    mutating func switchToInline(fromProfile profile: SSHProfile) {
        profileId = nil
        host = profile.host
        port = String(profile.port)
        username = profile.username
        authMethod = profile.authMethod
        privateKeyPath = profile.privateKeyPath
        applyAgentSocketPath(profile.agentSocketPath)
        jumpHosts = profile.jumpHosts
        totpMode = profile.totpMode
        totpAlgorithm = profile.totpAlgorithm
        totpDigits = profile.totpDigits
        totpPeriod = profile.totpPeriod
    }

    mutating func populateFields(from config: SSHConfiguration) {
        host = config.host
        port = String(config.port)
        username = config.username
        authMethod = config.authMethod
        privateKeyPath = config.privateKeyPath
        applyAgentSocketPath(config.agentSocketPath)
        jumpHosts = config.jumpHosts
        totpMode = config.totpMode
        totpAlgorithm = config.totpAlgorithm
        totpDigits = config.totpDigits
        totpPeriod = config.totpPeriod

        // Restore config host picker state if a config entry was used
        if config.useSSHConfig {
            selectedConfigHost = configEntries.first { $0.hostname == config.host || $0.host == config.host }?.host ?? ""
        } else {
            selectedConfigHost = ""
        }
    }

    mutating func applyAgentSocketPath(_ socketPath: String) {
        let option = SSHAgentSocketOption(socketPath: socketPath)
        agentSocketOption = option

        if option == .custom {
            customAgentSocketPath = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            customAgentSocketPath = ""
        }
    }
}
