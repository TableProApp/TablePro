//
//  DatabaseConnection+Portable.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProImport
import TableProPluginKit

internal extension SSLMode {
    init(_ portable: PortableSSLMode) {
        switch portable {
        case .disabled: self = .disabled
        case .preferred: self = .preferred
        case .required: self = .required
        case .verifyCA: self = .verifyCa
        case .verifyIdentity: self = .verifyIdentity
        }
    }

    var portableMode: PortableSSLMode {
        switch self {
        case .disabled: .disabled
        case .preferred: .preferred
        case .required: .required
        case .verifyCa: .verifyCA
        case .verifyIdentity: .verifyIdentity
        }
    }
}

internal extension DatabaseConnection {
    /// A shared file names a profile by id only, so it can link one this Mac already stores but never guess one;
    /// `credentialProfileId` is set only for a profile this import created.
    init(
        importing settings: ExportableConnection,
        id: UUID,
        groupId: UUID?,
        tagIds: [UUID],
        credentialProfileId: UUID?,
        resolvesSSHProfile: (UUID) -> Bool
    ) {
        var additionalFields = settings.additionalFields ?? [:]
        let legacyConnectTimeout = additionalFields
            .removeValue(forKey: Self.connectTimeoutSecondsKey)
            .flatMap(Int.init)
        let legacyQueryTimeout = additionalFields
            .removeValue(forKey: Self.queryTimeoutSecondsKey)
            .flatMap(Int.init)
        let host = settings.host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : settings.host

        self.init(
            id: id,
            name: settings.name,
            host: host,
            port: settings.port,
            database: settings.database,
            username: settings.username,
            type: DatabaseType(rawValue: settings.type),
            sshConfig: settings.sshConfig.map(SSHConfiguration.init(importing:)) ?? SSHConfiguration(),
            sslConfig: settings.sslConfig.map(SSLConfiguration.init(importing:)) ?? SSLConfiguration(),
            color: settings.color.flatMap { ConnectionColor(rawValue: $0) } ?? .none,
            iconName: LibrarySymbolCatalog.normalizedName(settings.iconName),
            tagIds: tagIds,
            groupId: groupId,
            sshProfileId: settings.sshProfileId
                .flatMap { UUID(uuidString: $0) }
                .flatMap { resolvesSSHProfile($0) ? $0 : nil },
            credentialMode: credentialProfileId.map { CredentialMode.profile(id: $0) } ?? .inline,
            tunnelCommandMode: settings.tunnelCommand.map { .inline(TunnelCommandConfiguration($0)) } ?? .disabled,
            safeModeLevel: SafeModeLevel(wireValue: settings.safeModeLevel, isReadOnly: false),
            aiPolicy: settings.aiPolicy.flatMap { AIConnectionPolicy(rawValue: $0) },
            redisDatabase: settings.redisDatabase,
            startupCommands: settings.startupCommands,
            localOnly: settings.localOnly ?? false,
            additionalFields: additionalFields
        )
        if let connectTimeout = Self.portableConnectTimeout(settings.connectTimeoutSeconds ?? legacyConnectTimeout) {
            connectTimeoutSeconds = connectTimeout
        }
        if let queryTimeout = Self.portableQueryTimeout(settings.queryTimeoutSeconds ?? legacyQueryTimeout) {
            queryTimeoutSeconds = queryTimeout
        }
    }

    static func portableConnectTimeout(_ seconds: Int?) -> Int? {
        seconds.flatMap { ConnectionTimeoutPolicy.connectTimeoutRange.contains($0) ? $0 : nil }
    }

    static func portableQueryTimeout(_ seconds: Int?) -> Int? {
        seconds.flatMap { queryTimeoutSecondsRange.contains($0) ? $0 : nil }
    }
}

internal extension SSHConfiguration {
    init(importing ssh: ExportableSSHConfig) {
        self.init()
        enabled = ssh.enabled
        host = ssh.host
        port = ssh.port
        username = ssh.username
        authMethod = SSHAuthMethod(carrying: ssh.authMethod)
        privateKeyPath = PathPortability.expandHome(ssh.privateKeyPath)
        agentSocketPath = PathPortability.expandHome(ssh.agentSocketPath)
        jumpHosts = (ssh.jumpHosts ?? []).map { jump in
            SSHJumpHost(
                host: jump.host,
                port: jump.port,
                username: jump.username,
                authMethod: SSHJumpAuthMethod(carrying: jump.authMethod),
                privateKeyPath: PathPortability.expandHome(jump.privateKeyPath)
            )
        }
        totpMode = ssh.totpMode.flatMap { TOTPMode(rawValue: $0) } ?? .none
        totpAlgorithm = ssh.totpAlgorithm.flatMap { TOTPAlgorithm(rawValue: $0) } ?? .sha1
        totpDigits = ssh.totpDigits ?? 6
        totpPeriod = ssh.totpPeriod ?? 30
        remoteFilePath = ssh.remoteFilePath ?? ""
        remoteFileAccess = ssh.remoteFileAccess.flatMap { RemoteFileAccess(rawValue: $0) } ?? .readOnlyCopy
    }
}

internal extension SSLConfiguration {
    /// A mode this build does not recognize imports as Required: guessing Disabled would send credentials in clear.
    init(importing ssl: ExportableSSLConfig) {
        self.init(
            mode: ssl.portableMode.map { SSLMode($0) } ?? .required,
            caCertificatePath: PathPortability.expandHome(ssl.caCertificatePath ?? ""),
            clientCertificatePath: PathPortability.expandHome(ssl.clientCertificatePath ?? ""),
            clientKeyPath: PathPortability.expandHome(ssl.clientKeyPath ?? "")
        )
    }
}

internal extension ExportableSSHConfig {
    init?(portable ssh: SSHConfiguration) {
        guard ssh.enabled else { return nil }
        let jumpHosts = ssh.jumpHosts.map { jump in
            ExportableJumpHost(
                host: jump.host,
                port: jump.port,
                username: jump.username,
                authMethod: jump.authMethod.rawValue,
                privateKeyPath: PathPortability.contractHome(jump.privateKeyPath)
            )
        }
        self.init(
            enabled: true,
            host: ssh.host,
            port: ssh.port,
            username: ssh.username,
            authMethod: ssh.authMethod.rawValue,
            privateKeyPath: PathPortability.contractHome(ssh.privateKeyPath),
            agentSocketPath: PathPortability.contractHome(ssh.agentSocketPath),
            jumpHosts: jumpHosts.isEmpty ? nil : jumpHosts,
            totpMode: ssh.totpMode == .none ? nil : ssh.totpMode.rawValue,
            totpAlgorithm: ssh.totpAlgorithm == .sha1 ? nil : ssh.totpAlgorithm.rawValue,
            totpDigits: ssh.totpDigits == 6 ? nil : ssh.totpDigits,
            totpPeriod: ssh.totpPeriod == 30 ? nil : ssh.totpPeriod,
            remoteFilePath: ssh.remoteFilePath.isEmpty ? nil : ssh.remoteFilePath,
            remoteFileAccess: ssh.remoteFileAccess == .readOnlyCopy ? nil : ssh.remoteFileAccess.rawValue
        )
    }
}

internal extension ExportableSSLConfig {
    init?(portable ssl: SSLConfiguration) {
        guard ssl.mode != .disabled else { return nil }
        self.init(
            mode: ssl.mode.portableMode.rawValue,
            caCertificatePath: PathPortability.contractHome(ssl.caCertificatePath),
            clientCertificatePath: PathPortability.contractHome(ssl.clientCertificatePath),
            clientKeyPath: PathPortability.contractHome(ssl.clientKeyPath)
        )
    }
}
