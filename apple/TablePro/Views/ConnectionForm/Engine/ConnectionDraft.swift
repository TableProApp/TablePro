//
//  ConnectionDraft.swift
//  TablePro
//

import Foundation
import TableProAutocomplete
import TableProPluginKit

struct ConnectionDraft: Equatable, Sendable {
    enum Endpoint: Hashable, Sendable {
        case hostAndPort
        case localSocket
    }

    var name: String = ""
    var type: DatabaseType
    var environment: ConnectionEnvironment = .none
    var endpoint: Endpoint = .hostAndPort
    var host: String = ""
    var portText: String = ""
    var database: String = ""
    var localSocketPath: String = ""
    var sshForwardUnixSocketPath: String = ""
    var credentials = CredentialsDraft()
    // Every plugin field of the type in one bag, secure values included; the engine strips secure ids before a write.
    var fieldValues: [String: String] = [:]
    var transport: ConnectionTunnelKind?
    var ssh = SSHDraft()
    var cloudflare = CloudflareDraft()
    var cloudSQLProxy = CloudSQLProxyDraft()
    var socksProxy = SOCKSProxyDraft()
    var tunnelCommand = TunnelCommandDraft()
    var ssl = SSLDraft()
    var options = OptionsDraft()
    var safety = SafetyDraft()
    var ai = AIDraft()
    var appearance = AppearanceDraft()

    init(type: DatabaseType, environment: ConnectionEnvironment = .none) {
        self.type = type
        self.environment = environment
    }

    var usesSSHServer: Bool { transport == .ssh || transport == .remoteFile }
}

struct CredentialsDraft: Equatable, Sendable {
    var mode: CredentialMode = .inline
    var username: String = ""
    var password: String = ""
    var promptsForPassword = false
    // Read only: it lives in connections.json and is carried over by the save.
    var passwordSource: PasswordSource?
    var storedPasswordState: ConnectionStorage.StoredSecretState = .absent

    var usesProfile: Bool { mode.profileId != nil }
}

struct SSLDraft: Equatable, Sendable {
    var mode: SSLMode = .disabled
    var origin: SSLModeOrigin = .typeDefault
    var caCertPath: String = ""
    var clientCertPath: String = ""
    var clientKeyPath: String = ""
    var clientKeyPassphrase: String = ""

    var configuration: SSLConfiguration {
        SSLConfiguration(
            mode: mode,
            caCertificatePath: caCertPath,
            clientCertificatePath: clientCertPath,
            clientKeyPath: clientKeyPath
        )
    }
}

struct OptionsDraft: Equatable, Sendable {
    var connectTimeoutSeconds: Int?
    var queryTimeoutSeconds: Int?
    var binaryInlineLimitKilobytes: Int?
    var completionIdentifierCase: SQLIdentifierCase = .default
    var startupCommands: String = ""
    var preConnectScript: String = ""
    var postDisconnectScript: String = ""
    var scriptTimeoutSeconds: Int?
    var localOnly = false
}

struct SafetyDraft: Equatable, Sendable {
    var safeModeLevel: SafeModeLevel = .silent
    // Until the user picks a level, a new connection's level follows its environment.
    var userSetSafeMode = false
    var commitMode: ConnectionCommitMode = .automatic
    var maskingRules: [MaskingRule] = []
}

struct AIDraft: Equatable, Sendable {
    var policy: AIConnectionPolicy?
    var rules: String = ""
    var externalAccess: ExternalAccessLevel = .readOnly
    var alwaysAllowedTools: [String] = []
    var revokedTools: Set<String> = []
}

struct AppearanceDraft: Equatable, Sendable {
    var color: ConnectionColor = .none
    var iconName: String?
    var tagIds: [UUID] = []
    var groupId: UUID?
}

// What the store read from the Keychain for a stored connection. Nil means not stored or unreadable.
struct DraftSecrets: Equatable, Sendable {
    var password: String?
    var passwordState: ConnectionStorage.StoredSecretState = .absent
    var sshPassword: String?
    var sshPasswordState: ConnectionStorage.StoredSecretState = .absent
    var sshKeyPassphrase: String?
    var sshKeyPassphraseState: ConnectionStorage.StoredSecretState = .absent
    var totpSecret: String?
    var sslClientKeyPassphrase: String?
    var cloudflareTokenId: String?
    var cloudflareTokenSecret: String?
    var cloudSQLServiceAccountKey: String?
    var socksPassword: String?
    var pluginSecureFields: [String: String] = [:]

    static let none = DraftSecrets()
}
