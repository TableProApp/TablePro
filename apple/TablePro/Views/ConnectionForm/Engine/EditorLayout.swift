//
//  EditorLayout.swift
//  TablePro
//

import Foundation

struct EditorLayout: Equatable, Sendable {
    var facets: [FacetLayout]

    var facetIDs: [ConnectionFacet] { facets.map(\.facet) }

    func facet(_ facet: ConnectionFacet) -> FacetLayout? {
        facets.first { $0.facet == facet }
    }

    func facet(containing row: EditorRow) -> ConnectionFacet? {
        facets.first { $0.contains(row) }?.facet
    }

    func contains(_ row: EditorRow) -> Bool {
        facet(containing: row) != nil
    }

    var allRows: [EditorRow] {
        facets.flatMap { $0.sections.flatMap(\.rows) }
    }
}

struct FacetLayout: Equatable, Identifiable, Sendable {
    var facet: ConnectionFacet
    var title: String
    var sections: [SectionLayout]

    var id: ConnectionFacet { facet }

    func contains(_ row: EditorRow) -> Bool {
        sections.contains { $0.rows.contains(row) }
    }

    func section(containing row: EditorRow) -> SectionLayout? {
        sections.first { $0.rows.contains(row) }
    }
}

struct SectionLayout: Equatable, Identifiable, Sendable {
    var id: String
    var title: String?
    var footer: String?
    var rows: [EditorRow]
}

enum EditorRow: Hashable, Sendable {
    case builtIn(BuiltInRow)
    case plugin(fieldID: String)

    var pluginFieldID: String? {
        guard case .plugin(let fieldID) = self else { return nil }
        return fieldID
    }

    var accessibilityIdentifier: String {
        switch self {
        case .builtIn(let row): return row.accessibilityIdentifier
        case .plugin(let fieldID): return "connection-field-\(fieldID)"
        }
    }
}

enum BuiltInRow: Hashable, Sendable {
    case name
    case type
    case environment
    case endpointKind
    case localSocketPath
    case host
    case port
    case portTLSNotice
    case databaseFile
    case database
    case credentialProfile
    case username
    case passwordSource
    case passwordMode
    case password
    case kerberosNote
    case pgpassStatus

    case transport
    case sshForwardSocketPath
    case remoteFilePath
    case remoteFileAccess
    case sshProfile
    case sshProfileMissing
    case sshConfigHost
    case sshHost
    case sshPort
    case sshUsername
    case sshAuthMethod
    case sshPassword
    case sshAgentSocket
    case sshIdentityFile
    case sshKeyFile
    case sshKeyPassphrase
    case sshNoAuthenticationNote
    case sshTOTPMode
    case sshTOTPSecret
    case sshTOTPAlgorithm
    case sshTOTPDigits
    case sshTOTPPeriod
    case jumpHost(UUID)
    case addJumpHost
    case cloudflareHostname
    case cloudflareAuthMethod
    case cloudflareSignIn
    case cloudflareTokenId
    case cloudflareTokenSecret
    case cloudflareAutomaticPort
    case cloudflareLocalPort
    case cloudflareExposeToLAN
    case cloudflareBinary
    case cloudSQLInstance
    case cloudSQLAuthMode
    case cloudSQLServiceAccountKey
    case cloudSQLIAMAuth
    case cloudSQLPrivateIP
    case cloudSQLAutomaticPort
    case cloudSQLLocalPort
    case cloudSQLBinary
    case socksHost
    case socksPort
    case socksUsername
    case socksPassword
    case tunnelCommandMethod
    case kubernetesResource
    case kubernetesNamespace
    case kubernetesContext
    case awsTarget
    case awsProfile
    case awsRegion
    case tunnelCommand
    case tunnelCommandExecutable
    case tunnelCommandPreview

    case sslMode
    case sslNoFallbackNotice
    case sslCertificateTrustNote
    case sslCACertificate
    case sslClientCertificate
    case sslClientKey
    case sslClientKeyPassphrase

    case icon
    case color
    case tags
    case group

    case safeModeLevel
    case manualCommit
    case maskingRules

    case externalAccess
    case aiPolicy
    case alwaysAllowedTools
    case aiRules

    case startupCommands
    case preConnectScript
    case scriptTimeout
    case postDisconnectScript

    case connectTimeout
    case queryTimeout
    case binaryInlineLimit
    case identifierCase
    case localOnly

    var accessibilityIdentifier: String {
        switch self {
        case .name: return "connection-form-name"
        case .type: return "connection-form-change-type"
        case .environment: return "connection-form-environment"
        case .endpointKind: return "connection-form-endpoint"
        case .localSocketPath: return "connection-form-socket-path"
        case .host: return "connection-form-host"
        case .port: return "connection-form-port"
        case .portTLSNotice: return "connection-form-port-tls-note"
        case .databaseFile: return "connection-form-file-path"
        case .database: return "connection-form-database"
        case .credentialProfile: return "connection-form-credential-profile"
        case .username: return "connection-form-username"
        case .passwordSource: return "password-source-test"
        case .passwordMode: return "connection-form-password-mode"
        case .password: return "connection-form-password"
        case .kerberosNote: return "connection-form-kerberos-note"
        case .pgpassStatus: return "connection-form-pgpass-status"
        case .transport: return "connection-form-transport"
        case .sshForwardSocketPath: return "connection-form-ssh-forward-socket"
        case .remoteFilePath: return "connection-form-remote-file-path"
        case .remoteFileAccess: return "connection-form-remote-file-access"
        case .sshProfile: return "connection-form-ssh-profile"
        case .sshProfileMissing: return "connection-form-ssh-profile-missing"
        case .sshConfigHost: return "connection-form-ssh-config-host"
        case .sshHost: return "connection-form-ssh-host"
        case .sshPort: return "connection-form-ssh-port"
        case .sshUsername: return "connection-form-ssh-username"
        case .sshAuthMethod: return "connection-form-ssh-auth-method"
        case .sshPassword: return "connection-form-ssh-password"
        case .sshAgentSocket: return "connection-form-ssh-agent-socket"
        case .sshIdentityFile: return "connection-form-ssh-identity-file"
        case .sshKeyFile: return "connection-form-ssh-key-file"
        case .sshKeyPassphrase: return "connection-form-ssh-key-passphrase"
        case .sshNoAuthenticationNote: return "connection-form-ssh-no-auth-note"
        case .sshTOTPMode: return "connection-form-ssh-totp-mode"
        case .sshTOTPSecret: return "connection-form-ssh-totp-secret"
        case .sshTOTPAlgorithm: return "connection-form-ssh-totp-algorithm"
        case .sshTOTPDigits: return "connection-form-ssh-totp-digits"
        case .sshTOTPPeriod: return "connection-form-ssh-totp-period"
        case .jumpHost(let id): return "connection-form-jump-host-\(id.uuidString)"
        case .addJumpHost: return "connection-form-add-jump-host"
        case .cloudflareHostname: return "connection-form-cloudflare-hostname"
        case .cloudflareAuthMethod: return "connection-form-cloudflare-auth-method"
        case .cloudflareSignIn: return "connection-form-cloudflare-sign-in"
        case .cloudflareTokenId: return "connection-form-cloudflare-token-id"
        case .cloudflareTokenSecret: return "connection-form-cloudflare-token-secret"
        case .cloudflareAutomaticPort: return "connection-form-cloudflare-automatic-port"
        case .cloudflareLocalPort: return "connection-form-cloudflare-local-port"
        case .cloudflareExposeToLAN: return "connection-form-cloudflare-expose-lan"
        case .cloudflareBinary: return "connection-form-cloudflare-binary"
        case .cloudSQLInstance: return "connection-form-cloud-sql-instance"
        case .cloudSQLAuthMode: return "connection-form-cloud-sql-auth-mode"
        case .cloudSQLServiceAccountKey: return "connection-form-cloud-sql-key"
        case .cloudSQLIAMAuth: return "connection-form-cloud-sql-iam"
        case .cloudSQLPrivateIP: return "connection-form-cloud-sql-private-ip"
        case .cloudSQLAutomaticPort: return "connection-form-cloud-sql-automatic-port"
        case .cloudSQLLocalPort: return "connection-form-cloud-sql-local-port"
        case .cloudSQLBinary: return "connection-form-cloud-sql-binary"
        case .socksHost: return "connection-form-socks-host"
        case .socksPort: return "connection-form-socks-port"
        case .socksUsername: return "connection-form-socks-username"
        case .socksPassword: return "connection-form-socks-password"
        case .tunnelCommandMethod: return "connection-form-tunnel-method"
        case .kubernetesResource: return "connection-form-kubernetes-resource"
        case .kubernetesNamespace: return "connection-form-kubernetes-namespace"
        case .kubernetesContext: return "connection-form-kubernetes-context"
        case .awsTarget: return "connection-form-aws-target"
        case .awsProfile: return "connection-form-aws-profile"
        case .awsRegion: return "connection-form-aws-region"
        case .tunnelCommand: return "connection-form-tunnel-command"
        case .tunnelCommandExecutable: return "connection-form-tunnel-executable"
        case .tunnelCommandPreview: return "connection-form-tunnel-preview"
        case .sslMode: return "connection-form-ssl-mode"
        case .sslNoFallbackNotice: return "connection-form-ssl-no-fallback"
        case .sslCertificateTrustNote: return "connection-form-ssl-trust-note"
        case .sslCACertificate: return "connection-form-ssl-ca"
        case .sslClientCertificate: return "connection-form-ssl-client-certificate"
        case .sslClientKey: return "connection-form-ssl-client-key"
        case .sslClientKeyPassphrase: return "connection-form-ssl-key-passphrase"
        case .icon: return "connection-form-icon"
        case .color: return "connection-form-color"
        case .tags: return "connection-form-tags"
        case .group: return "connection-form-group"
        case .safeModeLevel: return "connection-form-safe-mode"
        case .manualCommit: return "connection-form-manual-commit"
        case .maskingRules: return "connection-form-masking-rules"
        case .externalAccess: return "connection-form-external-access"
        case .aiPolicy: return "connection-form-ai-policy"
        case .alwaysAllowedTools: return "connection-form-always-allowed-tools"
        case .aiRules: return "connection-form-ai-rules"
        case .startupCommands: return "connection-form-startup-commands"
        case .preConnectScript: return "connection-form-pre-connect-script"
        case .scriptTimeout: return "connection-form-script-timeout"
        case .postDisconnectScript: return "connection-form-post-disconnect-script"
        case .connectTimeout: return "connection-form-connect-timeout"
        case .queryTimeout: return "connection-form-query-timeout"
        case .binaryInlineLimit: return "connection-form-binary-inline-limit"
        case .identifierCase: return "connection-form-identifier-case"
        case .localOnly: return "connection-form-local-only"
        }
    }
}

struct FieldIssue: Hashable, Identifiable, Sendable {
    enum Severity: Hashable, Sendable {
        case error
        case warning
    }

    var facet: ConnectionFacet
    var row: EditorRow
    var message: String
    var severity: Severity = .error

    var id: String { "\(facet.rawValue)|\(row.accessibilityIdentifier)|\(message)" }

    var blocksSave: Bool { severity == .error }

    var blocksTest: Bool { severity == .error }
}

struct FocusRequest: Equatable, Sendable {
    let facet: ConnectionFacet
    let row: EditorRow
    let token: UUID
}
