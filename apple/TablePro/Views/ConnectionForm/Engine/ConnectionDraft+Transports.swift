//
//  ConnectionDraft+Transports.swift
//  TablePro
//

import Foundation
import TableProSSHConfig
import TableProSSHTransport

// Each transport keeps its values while another is selected, so switching back within the window restores them.
struct SSHDraft: Equatable, Sendable {
    var profileId: UUID?
    // The configuration the record stored for its profile, kept so a profile this Mac cannot resolve stays linked.
    var profileSnapshot: SSHConfiguration?
    var host: String = ""
    var port: String = ""
    var username: String = ""
    var password: String = ""
    var authMethod: SSHAuthMethod = .password
    var privateKeyPath: String = ""
    var agentSocketOption: SSHAgentSocketOption = .systemDefault
    var customAgentSocketPath: String = ""
    var keyPassphrase: String = ""
    var selectedConfigHost: String = ""
    var jumpHosts: [SSHJumpHost] = []
    var totpMode: TOTPMode = .none
    var totpSecret: String = ""
    var totpAlgorithm: TOTPAlgorithm = .sha1
    var totpDigits: Int = 6
    var totpPeriod: Int = 30
    var remoteFilePath: String = ""
    var remoteFileAccess: RemoteFileAccess = .onServer
    var storedPasswordState: ConnectionStorage.StoredSecretState = .absent
    var storedKeyPassphraseState: ConnectionStorage.StoredSecretState = .absent
    // What the connection's or a profile's Keychain items filled in. Never cleared: the values stay on a switch to inline.
    private(set) var keychainSecrets: Set<SSHSecret> = []

    // Revealing a secret the Keychain handed over asks for authentication first.
    var savedSecrets: Set<SSHSecret> {
        var secrets = keychainSecrets
        if storedPasswordState != .absent { secrets.insert(.password) }
        if storedKeyPassphraseState != .absent { secrets.insert(.keyPassphrase) }
        return secrets
    }

    var resolvedAgentSocketPath: String {
        agentSocketOption.resolvedPath(customPath: customAgentSocketPath)
    }

    var clearsStoredPassword: Bool {
        password.isEmpty && storedPasswordState == .stored
    }

    var clearsStoredKeyPassphrase: Bool {
        keyPassphrase.isEmpty && storedKeyPassphraseState == .stored
    }

    func inlineConfiguration(enabled: Bool) -> SSHConfiguration {
        SSHConfiguration(
            enabled: enabled,
            host: host,
            port: ConnectionEditorEngine.parsePort(port),
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

    mutating func adoptKeychainSecrets(password: String?, keyPassphrase: String?, totpSecret: String?) {
        self.password = password ?? ""
        self.keyPassphrase = keyPassphrase ?? ""
        self.totpSecret = totpSecret ?? ""
        if !self.password.isEmpty { keychainSecrets.insert(.password) }
        if !self.keyPassphrase.isEmpty { keychainSecrets.insert(.keyPassphrase) }
        if !self.totpSecret.isEmpty { keychainSecrets.insert(.totpSecret) }
    }

    mutating func populateFields(from config: SSHConfiguration, configEntries: [SSHConfigEntry]) {
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
        customAgentSocketPath = option == .custom ? socketPath.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

struct CloudflareDraft: Equatable, Sendable {
    var accessHostname: String = ""
    var authMethod: CloudflareAuthMethod = .browserSSO
    var serviceTokenId: String = ""
    var serviceTokenSecret: String = ""
    var automaticPort = true
    var localPort: String = ""
    var exposeToLAN = false
    var binaryPath: String = ""

    var configuration: CloudflareConfiguration {
        CloudflareConfiguration(
            accessHostname: accessHostname.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: automaticPort ? nil : ConnectionEditorEngine.parsePort(localPort),
            authMethod: authMethod,
            exposeToLAN: exposeToLAN,
            binaryPath: binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    mutating func populateFields(from config: CloudflareConfiguration) {
        accessHostname = config.accessHostname
        authMethod = config.authMethod
        exposeToLAN = config.exposeToLAN
        binaryPath = config.binaryPath
        automaticPort = config.localPort == nil
        localPort = config.localPort.map(String.init) ?? ""
    }
}

struct CloudSQLProxyDraft: Equatable, Sendable {
    var instanceConnectionName: String = ""
    var authMode: CloudSQLProxyAuthMode = .applicationDefault
    var serviceAccountKeyJSON: String = ""
    var useIAMAuth = false
    var usePrivateIP = false
    var automaticPort = true
    var localPort: String = ""
    var binaryPath: String = ""

    var configuration: CloudSQLProxyConfiguration {
        CloudSQLProxyConfiguration(
            instanceConnectionName: instanceConnectionName.trimmingCharacters(in: .whitespacesAndNewlines),
            authMode: authMode,
            useIAMAuth: useIAMAuth,
            usePrivateIP: usePrivateIP,
            localPort: automaticPort ? nil : ConnectionEditorEngine.parsePort(localPort),
            binaryPath: binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var hasServiceAccountKey: Bool {
        !serviceAccountKeyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func populateFields(from config: CloudSQLProxyConfiguration) {
        instanceConnectionName = config.instanceConnectionName
        authMode = config.authMode
        useIAMAuth = config.useIAMAuth
        usePrivateIP = config.usePrivateIP
        binaryPath = config.binaryPath
        automaticPort = config.localPort == nil
        localPort = config.localPort.map(String.init) ?? ""
    }
}

struct SOCKSProxyDraft: Equatable, Sendable {
    var host: String = ""
    var port: String = "1080"
    var username: String = ""
    var password: String = ""

    var configuration: SOCKSProxyConfiguration {
        SOCKSProxyConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: ConnectionEditorEngine.parsePort(port) ?? 1_080,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct TunnelCommandDraft: Equatable, Sendable {
    var config = TunnelCommandConfiguration()

    var trimmedConfiguration: TunnelCommandConfiguration {
        var trimmed = config
        trimmed.command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.executablePath = config.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.kubernetesNamespace = config.kubernetesNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.kubernetesResource = config.kubernetesResource.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.kubernetesContext = config.kubernetesContext.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.awsTarget = config.awsTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.awsProfile = config.awsProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.awsRegion = config.awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }
}
