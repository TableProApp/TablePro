//
//  LibraryRecordMapping.swift
//  TablePro
//

import CryptoKit
import Foundation
import TableProFFI
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport

// The Mac's library models as the core stores them (core ADRs 0010 and 0054). A value the core holds that the Mac
// has no case for, such as a teal colour, is written back as it was while the Mac's value still reads as it.
nonisolated enum LibraryRecordMapping {
    // MARK: - Connections

    static func connection(_ stored: LibraryConnectionRecord, isFavorite: Bool) -> DatabaseConnection {
        let record = stored.connection
        let details = stored.details
        let device = stored.device
        let ssh = record.ssh.map { sshConfiguration($0, connectionId: record.id) }

        var additionalFields = details.additionalFields
        if let timeout = record.queryTimeoutSecs {
            additionalFields[DatabaseConnection.queryTimeoutSecondsKey] = String(timeout)
        }

        let tunnelMode: SSHTunnelMode
        let sshConfig: SSHConfiguration
        let sshProfileId: UUID?
        switch (ssh, details.sshProfileId.flatMap(UUID.init(uuidString:))) {
        case let (.some(config), profileId) where config.enabled:
            sshConfig = config
            sshProfileId = profileId
            tunnelMode = profileId.map { .profile(id: $0, snapshot: config) } ?? .inline(config)
        case let (.some(config), _):
            sshConfig = config
            sshProfileId = nil
            tunnelMode = .disabled
        case (.none, _):
            sshConfig = SSHConfiguration()
            sshProfileId = nil
            tunnelMode = .disabled
        }

        var connection = DatabaseConnection(
            id: UUID(uuidString: record.id) ?? UUID(),
            name: record.name,
            host: record.host,
            port: Int(record.port),
            database: record.database,
            username: record.username,
            type: DatabaseType(rawValue: record.driverId),
            sshConfig: sshConfig,
            sslConfig: sslConfiguration(record.tls),
            color: color(record.color),
            iconName: record.icon.flatMap(symbol),
            tagIds: record.tags.compactMap(UUID.init(uuidString:)),
            groupId: record.groupId.flatMap(UUID.init(uuidString:)),
            sshProfileId: sshProfileId,
            sshTunnelMode: tunnelMode,
            credentialMode: details.credentialProfileId.flatMap(UUID.init(uuidString:)).map { .profile(id: $0) } ?? .inline,
            cloudflareTunnelMode: device.cloudflareTunnel.map { .inline(cloudflare($0)) } ?? .disabled,
            cloudSQLProxyMode: device.cloudSqlProxy.map { .inline(cloudSQLProxy($0)) } ?? .disabled,
            socksProxyMode: device.socksProxy.map { .inline(socksProxy($0)) } ?? .disabled,
            tunnelCommandMode: device.tunnelCommand.map { .inline(tunnelCommand($0)) } ?? .disabled,
            safeModeLevel: safeMode(record.safeMode),
            aiPolicy: aiPolicy(record.aiPolicy ?? .appDefault),
            aiRules: details.aiRules,
            aiAlwaysAllowedTools: Set(details.aiAllowedTools),
            externalAccess: externalAccess(record.externalAccess ?? .readOnly),
            redisDatabase: details.redisDatabase.map(Int.init),
            startupCommands: details.startupSql,
            sortOrder: Int(record.order),
            localOnly: device.localOnly,
            isSample: device.isSample,
            isFavorite: isFavorite,
            passwordSource: passwordSource(reference: details.credentialReference, local: device.passwordSource),
            additionalFields: additionalFields
        )
        connection.sshRoute = details.sshRoute.flatMap(route)
        connection.origin = origin(device.origin)
        return connection
    }

    static func record(_ connection: DatabaseConnection, keeping stored: LibraryConnectionRecord?) -> LibraryConnectionRecord {
        let kept = stored?.connection
        var additionalFields = connection.additionalFields
        var queryTimeout: UInt32?
        if let raw = additionalFields[DatabaseConnection.queryTimeoutSecondsKey], let seconds = UInt32(raw),
           String(seconds) == raw {
            queryTimeout = seconds
            additionalFields.removeValue(forKey: DatabaseConnection.queryTimeoutSecondsKey)
        }

        let ssh: SshSettings?
        let sshProfileId: UUID?
        switch tunnel(of: connection) {
        case .disabled:
            var config = connection.sshConfig
            config.enabled = false
            ssh = config == SSHConfiguration() ? nil : sshSettings(config, enabled: false, keeping: kept?.ssh)
            sshProfileId = nil
        case .inline(let config):
            ssh = sshSettings(config, enabled: true, keeping: kept?.ssh)
            sshProfileId = nil
        case .profile(let id, let snapshot):
            ssh = sshSettings(snapshot, enabled: true, keeping: kept?.ssh)
            sshProfileId = id
        }

        let (reference, local) = passwordSourceRecords(connection.passwordSource)
        let record = ConnectionRecord(
            id: connection.id.uuidString,
            name: connection.name,
            driverId: connection.type.rawValue,
            host: connection.host,
            port: UInt16(clamping: connection.port),
            database: connection.database,
            username: connection.username,
            integratedAuth: kept?.integratedAuth ?? false,
            tls: tlsSettings(connection.sslConfig, keeping: kept?.tls),
            ssh: ssh,
            safeMode: safeModeTag(connection.preferredSafeModeLevel),
            queryTimeoutSecs: queryTimeout,
            color: colorId(connection.color, keeping: kept?.color),
            groupId: connection.groupId?.uuidString,
            lastOpenedMs: kept?.lastOpenedMs,
            tags: connection.tagIds.map(\.uuidString),
            aiPolicy: aiPolicyTag(connection.aiPolicy),
            externalAccess: externalAccessTag(connection.externalAccess),
            icon: icon(connection.iconName),
            order: UInt32(clamping: connection.sortOrder)
        )
        let details = ConnectionDetailsRecord(
            startupSql: connection.startupCommands,
            aiRules: connection.aiRules,
            aiAllowedTools: connection.aiAlwaysAllowedTools.sorted(),
            sshProfileId: sshProfileId?.uuidString,
            sshRoute: connection.sshRoute.map(routeRecord),
            credentialProfileId: connection.credentialMode.profileId?.uuidString,
            credentialReference: reference,
            redisDatabase: connection.redisDatabase.map { UInt32(clamping: $0) },
            additionalFields: additionalFields
        )
        let device = DeviceSettingsRecord(
            localOnly: connection.localOnly,
            isSample: connection.isSample,
            origin: originId(connection.origin, keeping: stored?.device.origin),
            passwordSource: local,
            cloudflareTunnel: cloudflareRecord(connection.cloudflareTunnelMode),
            cloudSqlProxy: cloudSQLProxyRecord(connection.cloudSQLProxyMode),
            socksProxy: socksProxyRecord(connection.socksProxyMode),
            tunnelCommand: tunnelCommandRecord(connection.tunnelCommandMode)
        )
        return LibraryConnectionRecord(connection: record, details: details, device: device)
    }

    // As DatabaseConnection's init reads the legacy fields, so a connection reads back the tunnel connections.json gave it.
    private static func tunnel(of connection: DatabaseConnection) -> SSHTunnelMode {
        guard case .disabled = connection.sshTunnelMode else { return connection.sshTunnelMode }
        if let profileId = connection.sshProfileId {
            var snapshot = connection.sshConfig
            snapshot.enabled = true
            return .profile(id: profileId, snapshot: snapshot)
        }
        return connection.sshConfig.enabled ? .inline(connection.sshConfig) : .disabled
    }

    // MARK: - Groups and tags

    static func group(_ record: GroupRecord) -> ConnectionGroup {
        ConnectionGroup(
            id: UUID(uuidString: record.id) ?? UUID(),
            name: record.name,
            color: color(record.color),
            iconName: record.icon.flatMap(symbol),
            parentId: record.parentId.flatMap(UUID.init(uuidString:)),
            sortOrder: Int(record.order)
        )
    }

    static func record(_ group: ConnectionGroup, keeping stored: GroupRecord?) -> GroupRecord {
        GroupRecord(
            id: group.id.uuidString,
            name: group.name,
            parentId: group.parentId?.uuidString,
            order: UInt32(clamping: group.sortOrder),
            color: colorId(group.color, keeping: stored?.color),
            icon: icon(group.iconName)
        )
    }

    static func tag(_ record: TagRecord) -> ConnectionTag {
        ConnectionTag(
            id: UUID(uuidString: record.id) ?? UUID(),
            name: record.name,
            isPreset: record.isPreset,
            color: color(record.color)
        )
    }

    static func record(_ tag: ConnectionTag, keeping stored: TagRecord?) -> TagRecord {
        TagRecord(
            id: tag.id.uuidString,
            name: tag.name,
            color: colorId(tag.color, keeping: stored?.color),
            isPreset: tag.isPreset
        )
    }

    // MARK: - Colours and icons

    private static let colorIds: [(ConnectionColor, String)] = [
        (.red, "red"), (.orange, "orange"), (.yellow, "yellow"), (.green, "green"),
        (.blue, "blue"), (.purple, "purple"), (.pink, "pink"), (.gray, "slate")
    ]

    // Teal, which no Mac draws, reads as no colour (ADR 0010, The CloudKit mapping).
    static func color(_ id: String?) -> ConnectionColor {
        guard let id else { return .none }
        return colorIds.first { $0.1 == id }?.0 ?? .none
    }

    static func colorId(_ color: ConnectionColor, keeping stored: String?) -> String? {
        if let stored, Self.color(stored) == color {
            return stored
        }
        return colorIds.first { $0.0 == color }?.1
    }

    static func icon(_ symbol: String?) -> LibraryIconRecord? {
        guard let symbol, !symbol.isEmpty else { return nil }
        return libraryIconForSymbol(symbol: symbol)
    }

    static func symbol(_ icon: LibraryIconRecord) -> String? {
        (try? libraryIconSymbol(icon: icon)) ?? nil
    }

    // MARK: - Levels and policies

    static func safeMode(_ tag: SafeModeTag) -> SafeModeLevel {
        switch tag {
        case .silent: .silent
        case .alert: .alert
        case .alertFull: .alertFull
        case .safeMode: .safeMode
        case .safeModeFull: .safeModeFull
        case .readOnly: .readOnly
        }
    }

    static func safeModeTag(_ level: SafeModeLevel) -> SafeModeTag {
        switch level {
        case .silent: .silent
        case .alert: .alert
        case .alertFull: .alertFull
        case .safeMode: .safeMode
        case .safeModeFull: .safeModeFull
        case .readOnly: .readOnly
        }
    }

    static func aiPolicy(_ tag: AiPolicyTag) -> AIConnectionPolicy? {
        switch tag {
        case .ask: .askEachTime
        case .allow: .alwaysAllow
        case .never: .never
        case .appDefault: nil
        }
    }

    static func aiPolicyTag(_ policy: AIConnectionPolicy?) -> AiPolicyTag {
        switch policy {
        case .askEachTime: .ask
        case .alwaysAllow: .allow
        case .never: .never
        case nil: .appDefault
        }
    }

    static func externalAccess(_ tag: ExternalAccessTag) -> ExternalAccessLevel {
        switch tag {
        case .blocked: .blocked
        case .readOnly: .readOnly
        case .readWrite: .readWrite
        }
    }

    static func externalAccessTag(_ level: ExternalAccessLevel) -> ExternalAccessTag {
        switch level {
        case .blocked: .blocked
        case .readOnly: .readOnly
        case .readWrite: .readWrite
        }
    }

    private static let originIds: [(ConnectionOrigin, String)] = [
        (.thisMac, "this_device"), (.imported, "imported"), (.synced, "synced"),
        (.link, "link"), (.linkedFolder, "linked_folder"), (.teamLibrary, "team_library")
    ]

    // An origin a newer build wrote reads as this Mac, as connections.json has always read one it did not know.
    static func origin(_ id: String) -> ConnectionOrigin {
        originIds.first { $0.1 == id }?.0 ?? .thisMac
    }

    static func originId(_ origin: ConnectionOrigin, keeping stored: String?) -> String {
        if let stored, Self.origin(stored) == origin {
            return stored
        }
        return originIds.first { $0.0 == origin }?.1 ?? "this_device"
    }

    // MARK: - TLS

    private static let tlsModes: [(SSLMode, TlsModeTag)] = [
        (.disabled, .disable), (.preferred, .prefer), (.required, .require),
        (.verifyCa, .verifyCa), (.verifyIdentity, .verifyFull)
    ]

    static func sslConfiguration(_ tls: TlsSettings) -> SSLConfiguration {
        SSLConfiguration(
            mode: sslMode(tls.mode),
            caCertificatePath: tls.caFile ?? "",
            clientCertificatePath: tls.clientCertificate ?? "",
            clientKeyPath: tls.clientKey ?? ""
        )
    }

    // Strict, which no Mac engine offers, reads as Verify Identity, the check it makes as well.
    static func sslMode(_ tag: TlsModeTag) -> SSLMode {
        tag == .strict ? .verifyIdentity : tlsModes.first { $0.1 == tag }?.0 ?? .disabled
    }

    static func tlsSettings(_ ssl: SSLConfiguration, keeping stored: TlsSettings?) -> TlsSettings {
        var mode = tlsModes.first { $0.0 == ssl.mode }?.1 ?? .disable
        if let stored, sslMode(stored.mode) == ssl.mode {
            mode = stored.mode
        }
        return TlsSettings(
            mode: mode,
            caFile: ssl.caCertificatePath.nilIfEmpty,
            clientCertificate: ssl.clientCertificatePath.nilIfEmpty,
            clientKey: ssl.clientKeyPath.nilIfEmpty,
            serverName: stored?.serverName
        )
    }

    // MARK: - SSH

    static func sshConfiguration(_ settings: SshSettings, connectionId: String) -> SSHConfiguration {
        let options = settings.options
        let keyPath: String
        let method: SSHAuthMethod
        switch settings.auth {
        case .agent:
            method = .sshAgent
            keyPath = options?.keptKeyPath ?? ""
        case let .privateKey(path, _):
            method = .privateKey
            keyPath = path ?? ""
        case .password:
            method = .password
            keyPath = options?.keptKeyPath ?? ""
        case .keyboardInteractive:
            method = .keyboardInteractive
            keyPath = options?.keptKeyPath ?? ""
        case .none:
            method = .none
            keyPath = options?.keptKeyPath ?? ""
        }
        return SSHConfiguration(
            enabled: settings.enabled ?? true,
            host: settings.host,
            port: settings.port.map(Int.init),
            username: settings.username ?? "",
            authMethod: method,
            privateKeyPath: keyPath,
            agentSocketPath: options?.agentSocket ?? "",
            jumpHosts: settings.jumpHosts.enumerated().map { index, hop in
                jumpHost(hop, at: index, connectionId: connectionId)
            },
            totpMode: totpMode(options?.totp.mode ?? .off),
            totpAlgorithm: totpAlgorithm(options?.totp.algorithm ?? .sha1),
            totpDigits: Int(options?.totp.digits ?? 6),
            totpPeriod: Int(options?.totp.period ?? 30),
            remoteFilePath: options?.remoteFilePath ?? "",
            remoteFileAccess: options?.remoteFileAccess == .onServer ? .onServer : .readOnlyCopy
        )
    }

    static func sshSettings(_ config: SSHConfiguration, enabled: Bool, keeping stored: SshSettings?) -> SshSettings {
        let keyPath = config.privateKeyPath.nilIfEmpty
        let auth: SshAuthTag
        switch config.authMethod {
        case .password:
            auth = .password
        case .privateKey:
            let hasPassphrase: Bool
            if case let .privateKey(_, stored)? = stored?.auth {
                hasPassphrase = stored
            } else {
                hasPassphrase = false
            }
            auth = .privateKey(path: keyPath, hasPassphrase: hasPassphrase)
        case .sshAgent:
            auth = .agent
        case .keyboardInteractive:
            auth = .keyboardInteractive
        case .none:
            auth = .none
        }
        let keptKeyPath = config.authMethod == .privateKey ? nil : keyPath
        return SshSettings(
            host: config.host,
            port: config.port.map { UInt16(clamping: $0) },
            username: config.username.nilIfEmpty,
            jumpHosts: config.jumpHosts.map(jumpHostRecord),
            auth: auth,
            enabled: enabled,
            options: SshOptionsRecord(
                keptKeyPath: keptKeyPath,
                agentSocket: config.agentSocketPath.nilIfEmpty,
                totp: SshTotpRecord(
                    mode: totpModeTag(config.totpMode),
                    algorithm: totpAlgorithmTag(config.totpAlgorithm),
                    digits: UInt32(clamping: config.totpDigits),
                    period: UInt32(clamping: config.totpPeriod)
                ),
                remoteFilePath: config.remoteFilePath.nilIfEmpty,
                remoteFileAccess: config.remoteFileAccess == .onServer ? .onServer : .readOnlyCopy
            )
        )
    }

    // A hop another app typed carries no id; one made from the connection and its place stays the same on every read.
    private static func jumpHost(_ hop: SshJumpHostRecord, at index: Int, connectionId: String) -> SSHJumpHost {
        SSHJumpHost(
            id: hop.id.flatMap(UUID.init(uuidString:)) ?? derivedHopId(connectionId: connectionId, index: index),
            host: hop.host,
            port: hop.port.map(Int.init),
            username: hop.username ?? "",
            authMethod: hop.auth == .privateKey ? .privateKey : .sshAgent,
            privateKeyPath: hop.keyPath ?? ""
        )
    }

    private static func jumpHostRecord(_ hop: SSHJumpHost) -> SshJumpHostRecord {
        SshJumpHostRecord(
            id: hop.id.uuidString,
            host: hop.host,
            port: hop.port.map { UInt16(clamping: $0) },
            username: hop.username.nilIfEmpty,
            auth: hop.authMethod == .privateKey ? .privateKey : .agent,
            keyPath: hop.privateKeyPath.nilIfEmpty
        )
    }

    private static func derivedHopId(connectionId: String, index: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(connectionId)/hop/\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func totpMode(_ tag: SshTotpModeTag) -> TOTPMode {
        switch tag {
        case .off: .none
        case .autoGenerate: .autoGenerate
        case .promptAtConnect: .promptAtConnect
        }
    }

    private static func totpModeTag(_ mode: TOTPMode) -> SshTotpModeTag {
        switch mode {
        case .none: .off
        case .autoGenerate: .autoGenerate
        case .promptAtConnect: .promptAtConnect
        }
    }

    private static func totpAlgorithm(_ tag: SshTotpAlgorithmTag) -> TOTPAlgorithm {
        switch tag {
        case .sha1: .sha1
        case .sha256: .sha256
        case .sha512: .sha512
        }
    }

    private static func totpAlgorithmTag(_ algorithm: TOTPAlgorithm) -> SshTotpAlgorithmTag {
        switch algorithm {
        case .sha1: .sha1
        case .sha256: .sha256
        case .sha512: .sha512
        }
    }

    private static func route(_ record: SshRouteRecord) -> PublishedSSHRoute? {
        guard let publisher = UUID(uuidString: record.publisher) else { return nil }
        return PublishedSSHRoute(
            version: Int(record.version),
            publisher: publisher,
            basis: record.basis,
            hops: record.hops.compactMap { hop in
                UUID(uuidString: hop.id).map {
                    PublishedSSHRoute.Hop(id: $0, alias: hop.alias, host: hop.host, port: Int(hop.port), username: hop.username)
                }
            },
            target: PublishedSSHRoute.Target(
                alias: record.target.alias,
                host: record.target.host,
                port: Int(record.target.port),
                username: record.target.username
            )
        )
    }

    private static func routeRecord(_ route: PublishedSSHRoute) -> SshRouteRecord {
        SshRouteRecord(
            version: UInt32(clamping: route.version),
            publisher: route.publisher.uuidString,
            basis: route.basis,
            hops: route.hops.map { hop in
                SshRouteHopRecord(
                    id: hop.id.uuidString,
                    alias: hop.alias,
                    host: hop.host,
                    port: UInt16(clamping: hop.port),
                    username: hop.username
                )
            },
            target: SshRouteTargetRecord(
                alias: route.target.alias,
                host: route.target.host,
                port: UInt16(clamping: route.target.port),
                username: route.target.username
            )
        )
    }

    // MARK: - Password sources

    // A reference names where the password is kept; a file or a command runs here, so only this Mac keeps it.
    static func passwordSource(
        reference: CredentialReferenceRecord?,
        local: LocalPasswordSourceRecord?
    ) -> PasswordSource? {
        switch local {
        case let .file(path)?:
            return .file(path: path)
        case let .command(shell, reuseSeconds)?:
            return .command(shell: shell, reuseSeconds: reuseSeconds.map(Int.init))
        case nil:
            break
        }
        switch reference {
        case let .env(variable)?:
            return .env(variable: variable)
        case let .onePassword(reference)?:
            return .onePassword(reference: reference)
        case let .vault(path, field)?:
            return .vault(path: path, field: field)
        case let .awsSecretsManager(secretId, jsonKey)?:
            return .awsSecretsManager(secretId: secretId, jsonKey: jsonKey)
        case let .vaultDatabaseRole(address, mount, role, auth)?:
            return .vaultDatabaseRole(VaultDatabaseRole(address: address, mount: mount, role: role, auth: vaultAuth(auth)))
        case nil:
            return nil
        }
    }

    static func passwordSourceRecords(
        _ source: PasswordSource?
    ) -> (reference: CredentialReferenceRecord?, local: LocalPasswordSourceRecord?) {
        switch source {
        case let .file(path)?:
            return (nil, .file(path: path))
        case let .command(shell, reuseSeconds)?:
            return (nil, .command(shell: shell, reuseSeconds: reuseSeconds.map { UInt32(clamping: $0) }))
        case let .env(variable)?:
            return (.env(variable: variable), nil)
        case let .onePassword(reference)?:
            return (.onePassword(reference: reference), nil)
        case let .vault(path, field)?:
            return (.vault(path: path, field: field), nil)
        case let .awsSecretsManager(secretId, jsonKey)?:
            return (.awsSecretsManager(secretId: secretId, jsonKey: jsonKey), nil)
        case let .vaultDatabaseRole(role)?:
            return (
                .vaultDatabaseRole(address: role.address, mount: role.mount, role: role.role, auth: vaultAuthRecord(role.auth)),
                nil
            )
        case nil:
            return (nil, nil)
        }
    }

    private static func vaultAuth(_ record: VaultAuthRecord) -> VaultAuthMethod {
        switch record {
        case .token:
            return .token
        case let .appRole(mount, roleId, secretIdPath):
            return .appRole(mount: mount, roleId: roleId, secretIdPath: secretIdPath)
        case let .oidc(mount, role):
            return .oidc(mount: mount, role: role)
        }
    }

    private static func vaultAuthRecord(_ method: VaultAuthMethod) -> VaultAuthRecord {
        switch method {
        case .token:
            return .token
        case let .appRole(mount, roleId, secretIdPath):
            return .appRole(mount: mount, roleId: roleId, secretIdPath: secretIdPath)
        case let .oidc(mount, role):
            return .oidc(mount: mount, role: role)
        }
    }

    // MARK: - Tunnels this Mac alone keeps

    private static func cloudflare(_ record: CloudflareTunnelRecord) -> CloudflareConfiguration {
        CloudflareConfiguration(
            accessHostname: record.accessHostname,
            localPort: record.localPort.map(Int.init),
            authMethod: record.authMethod == .serviceToken ? .serviceToken : .browserSSO,
            exposeToLAN: record.exposeToLan,
            binaryPath: record.binaryPath
        )
    }

    private static func cloudflareRecord(_ mode: CloudflareTunnelMode) -> CloudflareTunnelRecord? {
        guard case .inline(let config) = mode else { return nil }
        return CloudflareTunnelRecord(
            accessHostname: config.accessHostname,
            localPort: config.localPort.map { UInt16(clamping: $0) },
            authMethod: config.authMethod == .serviceToken ? .serviceToken : .browserSso,
            exposeToLan: config.exposeToLAN,
            binaryPath: config.binaryPath
        )
    }

    private static func cloudSQLProxy(_ record: CloudSqlProxyRecord) -> CloudSQLProxyConfiguration {
        CloudSQLProxyConfiguration(
            instanceConnectionName: record.instanceConnectionName,
            authMode: record.authMode == .serviceAccountKey ? .serviceAccountKey : .applicationDefault,
            useIAMAuth: record.useIamAuth,
            usePrivateIP: record.usePrivateIp,
            localPort: record.localPort.map(Int.init),
            binaryPath: record.binaryPath
        )
    }

    private static func cloudSQLProxyRecord(_ mode: CloudSQLProxyMode) -> CloudSqlProxyRecord? {
        guard case .inline(let config) = mode else { return nil }
        return CloudSqlProxyRecord(
            instanceConnectionName: config.instanceConnectionName,
            authMode: config.authMode == .serviceAccountKey ? .serviceAccountKey : .applicationDefault,
            useIamAuth: config.useIAMAuth,
            usePrivateIp: config.usePrivateIP,
            localPort: config.localPort.map { UInt16(clamping: $0) },
            binaryPath: config.binaryPath
        )
    }

    private static func socksProxy(_ record: SocksProxyRecord) -> SOCKSProxyConfiguration {
        SOCKSProxyConfiguration(host: record.host, port: Int(record.port), username: record.username)
    }

    private static func socksProxyRecord(_ mode: SOCKSProxyMode) -> SocksProxyRecord? {
        guard case .inline(let config) = mode else { return nil }
        return SocksProxyRecord(host: config.host, port: UInt16(clamping: config.port), username: config.username)
    }

    private static let tunnelMethods: [(TunnelCommandMethod, TunnelCommandMethodTag)] = [
        (.kubectl, .kubectl), (.awsSSM, .awsSsm), (.custom, .custom)
    ]

    private static func tunnelCommand(_ record: TunnelCommandRecord) -> TunnelCommandConfiguration {
        TunnelCommandConfiguration(
            method: tunnelMethods.first { $0.1 == record.method }?.0 ?? .custom,
            command: record.command,
            executablePath: record.executablePath,
            kubernetesNamespace: record.kubernetesNamespace,
            kubernetesResource: record.kubernetesResource,
            kubernetesContext: record.kubernetesContext,
            awsTarget: record.awsTarget,
            awsProfile: record.awsProfile,
            awsRegion: record.awsRegion
        )
    }

    private static func tunnelCommandRecord(_ mode: TunnelCommandMode) -> TunnelCommandRecord? {
        guard case .inline(let config) = mode else { return nil }
        return TunnelCommandRecord(
            method: tunnelMethods.first { $0.0 == config.method }?.1 ?? .custom,
            command: config.command,
            executablePath: config.executablePath,
            kubernetesNamespace: config.kubernetesNamespace,
            kubernetesResource: config.kubernetesResource,
            kubernetesContext: config.kubernetesContext,
            awsTarget: config.awsTarget,
            awsProfile: config.awsProfile,
            awsRegion: config.awsRegion
        )
    }
}
