import Foundation
import TableProSSHConfig
import TableProSSHTransport

struct SSHTunnelFormState {
    var enabled: Bool = false
    var profileId: UUID?
    var profiles: [SSHProfile] = []

    var showingCreateProfile: Bool = false
    var editingProfile: SSHProfile?
    var showingSaveAsProfile: Bool = false

    var host: String = ""
    var port: String = ""
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

    // What the Keychain held when the form opened, so an emptied field is told apart from an unreadable Keychain.
    private(set) var storedPasswordState: ConnectionStorage.StoredSecretState = .absent
    private(set) var storedKeyPassphraseState: ConnectionStorage.StoredSecretState = .absent
    private(set) var loadedTOTPSecret = false
    // Secrets read from a profile's Keychain stay in the fields after a switch to inline.
    private(set) var profileSecrets: Set<SSHSecret> = []

    var remoteFilePath: String = ""

    // New connections run on the server; a connection saved before the live mode existed decodes as the copy.
    var remoteFileAccess: RemoteFileAccess = .onServer

    var selectedProfile: SSHProfile? {
        guard let id = profileId else { return nil }
        return profiles.first { $0.id == id }
    }

    var resolvedAgentSocketPath: String {
        agentSocketOption.resolvedPath(customPath: customAgentSocketPath)
    }

    var server: SSHServerDraft {
        get {
            var draft = SSHServerDraft()
            draft.host = host
            draft.port = port
            draft.username = username
            draft.authMethod = authMethod
            draft.password = password
            draft.privateKeyPath = privateKeyPath
            draft.keyPassphrase = keyPassphrase
            draft.agentSocketOption = agentSocketOption
            draft.customAgentSocketPath = customAgentSocketPath
            draft.selectedConfigHost = selectedConfigHost
            draft.jumpHosts = jumpHosts
            draft.totpMode = totpMode
            draft.totpSecret = totpSecret
            draft.totpAlgorithm = totpAlgorithm
            draft.totpDigits = totpDigits
            draft.totpPeriod = totpPeriod
            return draft
        }
        set {
            host = newValue.host
            port = newValue.port
            username = newValue.username
            authMethod = newValue.authMethod
            password = newValue.password
            privateKeyPath = newValue.privateKeyPath
            keyPassphrase = newValue.keyPassphrase
            agentSocketOption = newValue.agentSocketOption
            customAgentSocketPath = newValue.customAgentSocketPath
            selectedConfigHost = newValue.selectedConfigHost
            jumpHosts = newValue.jumpHosts
            totpMode = newValue.totpMode
            totpSecret = newValue.totpSecret
            totpAlgorithm = newValue.totpAlgorithm
            totpDigits = newValue.totpDigits
            totpPeriod = newValue.totpPeriod
        }
    }

    // Revealing a secret the Keychain handed over asks for authentication first.
    var savedSecrets: Set<SSHSecret> {
        var secrets: Set<SSHSecret> = []
        if storedPasswordState != .absent { secrets.insert(.password) }
        if storedKeyPassphraseState != .absent { secrets.insert(.keyPassphrase) }
        if loadedTOTPSecret { secrets.insert(.totpSecret) }
        return secrets.union(profileSecrets)
    }

    func buildInlineConfig() -> SSHConfiguration {
        SSHConfiguration(
            enabled: enabled,
            host: host,
            port: Int(port),
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod,
            remoteFilePath: remoteFilePath,
            remoteFileAccess: remoteFileAccess
        )
    }

    // The remote path lives on the connection: two connections through one bastion name different files.
    func buildSSHConfig() -> SSHConfiguration {
        guard let profileId, let profile = profiles.first(where: { $0.id == profileId }) else {
            return buildInlineConfig()
        }
        var config = profile.toSSHConfiguration()
        config.remoteFilePath = remoteFilePath
        config.remoteFileAccess = remoteFileAccess
        return config
    }

    mutating func load(from connection: DatabaseConnection) {
        switch connection.sshTunnelMode {
        case .disabled:
            enabled = false
            profileId = nil
        case .inline(let config):
            enabled = true
            profileId = nil
            populateFields(from: config)
            remoteFilePath = config.remoteFilePath
            remoteFileAccess = config.remoteFileAccess
        case .profile(let id, let snapshot):
            enabled = true
            profileId = id
            populateFields(from: snapshot)
            remoteFilePath = connection.sshConfig.remoteFilePath
            remoteFileAccess = connection.sshConfig.remoteFileAccess
        }
    }

    @MainActor
    mutating func loadSecrets(connectionId: UUID, storage: ConnectionStorage) {
        if case .profile(let profileId, _) = buildTunnelMode() {
            adoptProfileSecrets(
                password: SSHProfileStorage.shared.loadSSHPassword(for: profileId) ?? "",
                keyPassphrase: SSHProfileStorage.shared.loadKeyPassphrase(for: profileId) ?? "",
                totpSecret: SSHProfileStorage.shared.loadTOTPSecret(for: profileId) ?? ""
            )
        } else {
            profileSecrets = []
            storedPasswordState = storage.sshPasswordState(for: connectionId)
            storedKeyPassphraseState = storage.keyPassphraseState(for: connectionId)
            password = storage.loadSSHPassword(for: connectionId) ?? ""
            keyPassphrase = storage.loadKeyPassphrase(for: connectionId) ?? ""
            totpSecret = storage.loadTOTPSecret(for: connectionId) ?? ""
            loadedTOTPSecret = !totpSecret.isEmpty
        }
    }

    mutating func adoptProfileSecrets(password: String, keyPassphrase: String, totpSecret: String) {
        self.password = password
        self.keyPassphrase = keyPassphrase
        self.totpSecret = totpSecret
        loadedTOTPSecret = false
        profileSecrets = server.filledSecrets
    }

    // Without this the old inline secret stays in the Keychain and the next connect still uses it.
    var clearsStoredPassword: Bool {
        password.isEmpty && storedPasswordState == .stored
    }

    var clearsStoredKeyPassphrase: Bool {
        keyPassphrase.isEmpty && storedKeyPassphraseState == .stored
    }

    func buildTunnelMode() -> SSHTunnelMode {
        guard enabled else { return .disabled }
        if let profileId, let profile = profiles.first(where: { $0.id == profileId }) {
            var snapshot = profile.toSSHConfiguration()
            snapshot.remoteFilePath = remoteFilePath
            snapshot.remoteFileAccess = remoteFileAccess
            return .profile(id: profileId, snapshot: snapshot)
        }
        return .inline(buildInlineConfig())
    }

    mutating func disable() {
        enabled = false
        profileId = nil
        host = ""
        port = ""
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
        profileSecrets = []
    }

    mutating func switchToInline(fromProfile profile: SSHProfile) {
        profileId = nil
        host = profile.host
        port = profile.port.map(String.init) ?? ""
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
        port = config.port.map(String.init) ?? ""
        username = config.username
        authMethod = config.authMethod
        privateKeyPath = config.privateKeyPath
        applyAgentSocketPath(config.agentSocketPath)
        jumpHosts = config.jumpHosts
        totpMode = config.totpMode
        totpAlgorithm = config.totpAlgorithm
        totpDigits = config.totpDigits
        totpPeriod = config.totpPeriod

        selectedConfigHost = configEntries.first { $0.host == config.host }?.host ?? ""
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
