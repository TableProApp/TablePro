import CryptoKit
import Foundation
import TableProFFI
import TableProModels
import TableProSSHTransport

// The iOS library models as the core stores them (core ADRs 0010 and 0054). Each part a write names keeps the stored
// value while iOS still reads it as the same, so what only the Mac or the core holds, such as a Safe Mode level iOS has
// no case for, an SSH key's passphrase flag or a TLS server name, comes back unchanged.
nonisolated enum LibraryRecordMapping {
    static let redisDatabaseKey = "redisDatabase"

    // MARK: - Connections

    // `earlier` holds the flags an earlier build kept in UserDefaults, read until they move into the record.
    static func connection(
        _ stored: LibraryConnectionRecord,
        isFavorite: Bool,
        earlier: ConnectionDeviceFlags = ConnectionDeviceFlags()
    ) -> DatabaseConnection {
        let record = stored.connection
        let details = stored.details
        let id = UUID(uuidString: record.id) ?? derivedId(record.id, "connection")
        let level = safeMode(record.safeMode)
        let legacyRequire = stored.device.tlsModeUnsettled || earlier.legacySSLRequire.contains(id)
        let ssl = sslConfiguration(record.tls, legacyRequire: legacyRequire)
        var additionalFields = details.additionalFields
        if let database = details.redisDatabase {
            additionalFields[redisDatabaseKey] = String(database)
        }
        var connection = DatabaseConnection(
            id: id,
            name: record.name,
            type: DatabaseType(rawValue: record.driverId),
            host: record.host,
            port: Int(record.port),
            username: record.username,
            database: record.database,
            color: color(record.color),
            iconName: record.icon.flatMap(symbol),
            isReadOnly: level.blocksWrites,
            safeModeLevel: level,
            queryTimeoutSeconds: record.queryTimeoutSecs.map(Int.init),
            additionalFields: additionalFields,
            sshEnabled: record.ssh.map { $0.enabled ?? true } ?? false,
            sshConfiguration: record.ssh.map { sshConfiguration($0, connectionId: record.id) },
            sslEnabled: ssl.map { $0.mode != .disable } ?? false,
            sslConfiguration: ssl,
            groupId: record.groupId.flatMap(UUID.init(uuidString:)),
            tagIds: record.tags.compactMap(UUID.init(uuidString:)),
            sortOrder: Int(record.order),
            isFavorite: isFavorite,
            isSample: stored.device.isSample
        )
        connection.sshProfileId = details.sshProfileId.flatMap(UUID.init(uuidString:))
        connection.clearsSSHProfileLink = stored.device.sshProfileUnlinked || earlier.profileLinksToClear.contains(id)
        connection.sshRoute = details.sshRoute.flatMap(route)
        return connection
    }

    static func record(_ connection: DatabaseConnection, keeping stored: LibraryConnectionRecord?) -> LibraryConnectionRecord {
        let kept = stored?.connection
        let keptDetails = stored?.details
        var additionalFields = connection.additionalFields
        var redisDatabase: UInt32?
        if let raw = additionalFields[redisDatabaseKey], let database = UInt32(raw), String(database) == raw {
            redisDatabase = database
            additionalFields.removeValue(forKey: redisDatabaseKey)
        }
        let record = ConnectionRecord(
            id: connection.id.uuidString,
            name: connection.name,
            driverId: connection.type.rawValue,
            host: connection.host,
            port: UInt16(clamping: connection.port),
            database: connection.database,
            username: connection.username,
            integratedAuth: kept?.integratedAuth ?? false,
            tls: tlsSettings(shownSSL(connection), keeping: kept?.tls),
            ssh: sshSettings(connection, keeping: kept),
            safeMode: safeModeTag(connection.safeModeLevel, keeping: kept?.safeMode),
            queryTimeoutSecs: connection.queryTimeoutSeconds.map { UInt32(clamping: $0) },
            color: colorId(connection.color, keeping: kept?.color),
            groupId: connection.groupId?.uuidString,
            lastOpenedMs: kept?.lastOpenedMs,
            tags: connection.tagIds.map(\.uuidString),
            aiPolicy: kept?.aiPolicy,
            externalAccess: kept?.externalAccess,
            icon: icon(connection.iconName, keeping: kept?.icon),
            order: UInt32(clamping: connection.sortOrder)
        )
        let details = ConnectionDetailsRecord(
            startupSql: keptDetails?.startupSql,
            aiRules: keptDetails?.aiRules,
            aiAllowedTools: keptDetails?.aiAllowedTools ?? [],
            sshProfileId: connection.sshProfileId?.uuidString,
            sshRoute: connection.sshRoute.map { routeRecord($0, keeping: keptDetails?.sshRoute) },
            credentialProfileId: keptDetails?.credentialProfileId,
            credentialReference: keptDetails?.credentialReference,
            redisDatabase: redisDatabase,
            additionalFields: additionalFields
        )
        var device = stored?.device ?? DeviceSettingsRecord(
            localOnly: false,
            isSample: false,
            origin: "this_device",
            passwordSource: nil,
            cloudflareTunnel: nil,
            cloudSqlProxy: nil,
            socksProxy: nil,
            tunnelCommand: nil
        )
        device.isSample = connection.isSample
        device.tlsModeUnsettled = connection.sslConfiguration?.isLegacyRequire == true
        device.sshProfileUnlinked = connection.clearsSSHProfileLink
        return LibraryConnectionRecord(connection: record, details: details, device: device)
    }

    // MARK: - Groups and tags

    static func group(_ record: GroupRecord) -> ConnectionGroup {
        ConnectionGroup(
            id: UUID(uuidString: record.id) ?? derivedId(record.id, "group"),
            name: record.name,
            sortOrder: Int(record.order),
            color: color(record.color),
            iconName: record.icon.flatMap(symbol),
            parentId: record.parentId.flatMap(UUID.init(uuidString:))
        )
    }

    static func record(_ group: ConnectionGroup, keeping stored: GroupRecord?) -> GroupRecord {
        GroupRecord(
            id: group.id.uuidString,
            name: group.name,
            parentId: group.parentId?.uuidString,
            order: UInt32(clamping: group.sortOrder),
            color: colorId(group.color, keeping: stored?.color),
            icon: icon(group.iconName, keeping: stored?.icon)
        )
    }

    static func tag(_ record: TagRecord) -> ConnectionTag {
        ConnectionTag(
            id: UUID(uuidString: record.id) ?? derivedId(record.id, "tag"),
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

    // Teal, which no Apple app draws, reads as no colour (ADR 0010, The CloudKit mapping).
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

    static func icon(_ symbol: String?, keeping stored: LibraryIconRecord?) -> LibraryIconRecord? {
        if let stored, Self.symbol(stored) == symbol {
            return stored
        }
        guard let symbol, !symbol.isEmpty else { return nil }
        return libraryIconForSymbol(symbol: symbol)
    }

    static func symbol(_ icon: LibraryIconRecord) -> String? {
        (try? libraryIconSymbol(icon: icon)) ?? nil
    }

    // MARK: - Safe Mode

    // The Mac's levels between Silent and Read-Only all ask before a write, which is what Confirm Writes does here.
    static func safeMode(_ tag: SafeModeTag) -> SafeModeLevel {
        switch tag {
        case .silent: .off
        case .alert, .alertFull, .safeMode, .safeModeFull: .confirmWrites
        case .readOnly: .readOnly
        }
    }

    static func safeModeTag(_ level: SafeModeLevel, keeping stored: SafeModeTag?) -> SafeModeTag {
        if let stored, safeMode(stored) == level {
            return stored
        }
        switch level {
        case .off: return .silent
        case .confirmWrites: return .alert
        case .readOnly: return .readOnly
        }
    }

    // MARK: - TLS

    // Strict, which no iOS engine offers, reads as Verify Full, the check it makes as well. Disable with no files is
    // no configuration, as a new connection holds it.
    static func sslConfiguration(_ tls: TlsSettings, legacyRequire: Bool) -> SSLConfiguration? {
        let files = [tls.caFile, tls.clientCertificate, tls.clientKey].compactMap { $0 }
        if tls.mode == .disable, files.allSatisfy(\.isEmpty) {
            return nil
        }
        let mode: SSLConfiguration.SSLMode = switch tls.mode {
        case .disable: .disable
        case .prefer, .require: .require
        case .verifyCa: .verifyCa
        case .verifyFull, .strict: .verifyFull
        }
        return SSLConfiguration(
            mode: mode,
            caCertificatePath: tls.caFile,
            clientCertificatePath: tls.clientCertificate,
            clientKeyPath: tls.clientKey,
            isMacPreferred: tls.mode == .prefer,
            isLegacyRequire: legacyRequire
        )
    }

    // SSL switched on with no configuration, as an older build could store it, opens as Required (`DriverSSLConfiguration`).
    static func shownSSL(_ connection: DatabaseConnection) -> SSLConfiguration? {
        guard connection.sslConfiguration == nil, connection.sslEnabled else { return connection.sslConfiguration }
        return SSLConfiguration(mode: .require)
    }

    static func tlsSettings(_ ssl: SSLConfiguration?, keeping stored: TlsSettings?) -> TlsSettings {
        if let stored, sslConfiguration(stored, legacyRequire: ssl?.isLegacyRequire == true) == ssl {
            return stored
        }
        let shown = ssl ?? SSLConfiguration()
        let mode: TlsModeTag = switch shown.mode {
        case .disable: .disable
        case .require: shown.isMacPreferred ? .prefer : .require
        case .verifyCa: .verifyCa
        case .verifyFull: .verifyFull
        }
        return TlsSettings(
            mode: mode,
            caFile: shown.caCertificatePath,
            clientCertificate: shown.clientCertificatePath,
            clientKey: shown.clientKeyPath,
            serverName: stored?.serverName
        )
    }

    // MARK: - SSH

    static func sshConfiguration(_ settings: SshSettings, connectionId: String) -> SSHConfiguration {
        let keyPath: String?
        let method: SSHConfiguration.SSHAuthMethod
        switch settings.auth {
        case let .privateKey(path, _):
            method = .privateKey
            keyPath = path
        case .agent:
            method = .sshAgent
            keyPath = settings.options?.keptKeyPath
        case .password:
            method = .password
            keyPath = settings.options?.keptKeyPath
        case .keyboardInteractive:
            method = .keyboardInteractive
            keyPath = settings.options?.keptKeyPath
        case .none:
            method = .none
            keyPath = settings.options?.keptKeyPath
        }
        var config = SSHConfiguration(
            host: settings.host,
            port: settings.port.map(Int.init),
            username: settings.username ?? "",
            authMethod: method,
            privateKeyPath: keyPath,
            jumpHosts: settings.jumpHosts.enumerated().map { index, hop in
                jumpHost(hop, at: index, connectionId: connectionId)
            }
        )
        config.macEnabled = settings.enabled ?? true
        if let options = settings.options {
            config.macAgentSocketPath = options.agentSocket
            config.macRemoteFilePath = options.remoteFilePath
            config.macRemoteFileAccess = options.remoteFileAccess == .onServer ? RemoteFileSpelling.onServer : nil
            if options.totp != defaultTotp {
                config.totpMode = totpMode(options.totp.mode).rawValue
                config.totpAlgorithm = totpAlgorithm(options.totp.algorithm).rawValue
                config.totpDigits = Int(options.totp.digits)
                config.totpPeriod = Int(options.totp.period)
            }
        }
        return config
    }

    private static func sshSettings(_ connection: DatabaseConnection, keeping kept: ConnectionRecord?) -> SshSettings? {
        guard let config = connection.sshConfiguration else { return nil }
        let stored = kept?.ssh
        if let stored, sshConfiguration(stored, connectionId: connection.id.uuidString) == shownConfiguration(connection) {
            return stored
        }
        let auth: SshAuthTag
        switch config.authMethod {
        case .password:
            auth = .password
        case .privateKey:
            var hasPassphrase = false
            if case let .privateKey(_, storedPassphrase)? = stored?.auth {
                hasPassphrase = storedPassphrase
            }
            auth = .privateKey(path: config.privateKeyPath, hasPassphrase: hasPassphrase)
        case .sshAgent:
            auth = .agent
        case .keyboardInteractive:
            auth = .keyboardInteractive
        case .none:
            auth = .none
        }
        let storedHops = Dictionary(
            (stored?.jumpHosts ?? []).enumerated().map { index, hop in
                let read = jumpHost(hop, at: index, connectionId: connection.id.uuidString)
                return (read.id, (read: read, record: hop))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return SshSettings(
            host: config.host,
            port: config.port.map { UInt16(clamping: $0) },
            username: Self.kept(config.username, stored: stored?.username),
            jumpHosts: config.jumpHosts.map { hop in
                jumpHostRecord(hop, keeping: storedHops[hop.id])
            },
            auth: auth,
            enabled: connection.sshEnabled,
            options: SshOptionsRecord(
                keptKeyPath: config.authMethod == .privateKey ? nil : config.privateKeyPath,
                agentSocket: config.macAgentSocketPath,
                totp: totpRecord(config),
                remoteFilePath: config.macRemoteFilePath,
                remoteFileAccess: config.macRemoteFileAccess == RemoteFileSpelling.onServer ? .onServer : .readOnlyCopy
            )
        )
    }

    // The configuration as a read from the core gives it back, so a write of what was read keeps the stored settings.
    private static func shownConfiguration(_ connection: DatabaseConnection) -> SSHConfiguration? {
        guard var config = connection.sshConfiguration else { return nil }
        config.macEnabled = connection.sshEnabled
        config.macUseSSHConfig = nil
        if config.macRemoteFileAccess != RemoteFileSpelling.onServer {
            config.macRemoteFileAccess = nil
        }
        return config
    }

    private enum RemoteFileSpelling {
        static let onServer = "onServer"
    }

    private static let defaultTotp = SshTotpRecord(mode: .off, algorithm: .sha1, digits: 6, period: 30)

    private static func totpRecord(_ config: SSHConfiguration) -> SshTotpRecord {
        guard let raw = config.totpMode else { return defaultTotp }
        return SshTotpRecord(
            mode: totpModeTag(TOTPMode(rawValue: raw) ?? .none),
            algorithm: totpAlgorithmTag(config.totpAlgorithm.flatMap(TOTPAlgorithm.init(rawValue:)) ?? .sha1),
            digits: UInt32(clamping: config.totpDigits ?? 6),
            period: UInt32(clamping: config.totpPeriod ?? 30)
        )
    }

    // A hop another app typed carries no id; one made from the connection and its place stays the same on every read.
    private static func jumpHost(_ hop: SshJumpHostRecord, at index: Int, connectionId: String) -> SSHJumpHost {
        // The core gives ids in lower case and iOS in upper case, so one connection derives one id either way.
        let base = UUID(uuidString: connectionId)?.uuidString ?? connectionId
        return SSHJumpHost(
            id: hop.id.flatMap(UUID.init(uuidString:)) ?? derivedId(base, "hop/\(index)"),
            host: hop.host,
            port: hop.port.map(Int.init),
            username: hop.username ?? "",
            macAuthMethod: hop.auth == .privateKey ? .privateKey : .sshAgent,
            macPrivateKeyPath: hop.keyPath ?? ""
        )
    }

    private static func jumpHostRecord(
        _ hop: SSHJumpHost,
        keeping stored: (read: SSHJumpHost, record: SshJumpHostRecord)?
    ) -> SshJumpHostRecord {
        if let stored, stored.read == hop {
            return stored.record
        }
        return SshJumpHostRecord(
            id: hop.id.uuidString,
            host: hop.host,
            port: hop.port.map { UInt16(clamping: $0) },
            username: Self.kept(hop.username, stored: stored?.record.username),
            auth: hop.macAuthMethod == .privateKey ? .privateKey : .agent,
            keyPath: hop.macPrivateKeyPath.isEmpty ? nil : hop.macPrivateKeyPath
        )
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

    // MARK: - The Mac's SSH route

    private static func route(_ record: SshRouteRecord) -> PublishedSSHRoute? {
        guard let publisher = UUID(uuidString: record.publisher) else { return nil }
        let target = PublishedSSHRoute.Target(
            alias: record.target.alias,
            host: record.target.host,
            port: Int(record.target.port),
            username: record.target.username
        )
        var route = PublishedSSHRoute(
            publisher: publisher,
            input: PublishedSSHRoute.Input(host: target.host, port: target.port, username: target.username, jumpHosts: []),
            hops: record.hops.compactMap { hop in
                UUID(uuidString: hop.id).map {
                    PublishedSSHRoute.Hop(id: $0, alias: hop.alias, host: hop.host, port: Int(hop.port), username: hop.username)
                }
            },
            target: target
        )
        // As the Mac published it, never derived again here.
        route.version = Int(record.version)
        route.basis = record.basis
        return route
    }

    private static func routeRecord(_ route: PublishedSSHRoute, keeping stored: SshRouteRecord?) -> SshRouteRecord {
        if let stored, Self.route(stored) == route {
            return stored
        }
        return SshRouteRecord(
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

    // MARK: - Helpers

    // iOS shows an absent value as empty, so an empty one keeps whichever form the store held.
    private static func kept(_ value: String, stored: String?) -> String? {
        value.isEmpty && stored != "" ? nil : value
    }

    // Stable for an id that is not a UUID, so a record no iOS id names reads the same each time.
    static func derivedId(_ base: String, _ role: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(base)/\(role)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
