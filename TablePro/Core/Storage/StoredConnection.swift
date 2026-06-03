//
//  StoredConnection.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct StoredConnection: Codable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let database: String
    let username: String
    let type: String

    // SSH Configuration
    let sshEnabled: Bool
    let sshHost: String
    let sshPort: Int?
    let sshUsername: String
    let sshAuthMethod: String
    let sshPrivateKeyPath: String
    let sshAgentSocketPath: String

    // SSL Configuration
    let sslMode: String
    let sslCaCertificatePath: String
    let sslClientCertificatePath: String
    let sslClientKeyPath: String

    // Color, Tag, and Group
    let color: String
    let tagId: String?
    let groupId: String?
    let sshProfileId: String?

    // Safe mode level
    let safeModeLevel: String

    // AI policy
    let aiPolicy: String?

    // AI rules text included in the system prompt for this connection
    let aiRules: String?

    // AI tools whitelisted for this connection
    let aiAlwaysAllowedTools: [String]?

    // MongoDB-specific
    let mongoAuthSource: String?
    let mongoReadPreference: String?
    let mongoWriteConcern: String?

    // Redis-specific
    let redisDatabase: Int?

    // MSSQL schema
    let mssqlSchema: String?

    // Oracle service name
    let oracleServiceName: String?

    // Startup commands
    let startupCommands: String?

    // Sort order for sync
    let sortOrder: Int

    // Local-only (excluded from iCloud sync)
    let localOnly: Bool

    let isSample: Bool

    let isFavorite: Bool

    // TOTP configuration
    let totpMode: String
    let totpAlgorithm: String
    let totpDigits: Int
    let totpPeriod: Int

    // SSH tunnel mode (v2 JSON blob preserving jump hosts + profile links)
    let sshTunnelModeJson: Data?

    // Cloudflare Access TCP tunnel mode (JSON blob)
    let cloudflareTunnelModeJson: Data?

    // Plugin-driven additional fields
    let additionalFields: [String: String]?

    // Password source (file, env, or command) for connections provisioned outside the app
    let passwordSource: PasswordSource?

    init(from connection: DatabaseConnection) {
        self.id = connection.id
        self.name = connection.name
        self.host = connection.host
        self.port = connection.port
        self.database = connection.database
        self.username = connection.username
        self.type = connection.type.rawValue

        // SSH Configuration
        self.sshEnabled = connection.sshConfig.enabled
        self.sshHost = connection.sshConfig.host
        self.sshPort = connection.sshConfig.port
        self.sshUsername = connection.sshConfig.username
        self.sshAuthMethod = connection.sshConfig.authMethod.rawValue
        self.sshPrivateKeyPath = connection.sshConfig.privateKeyPath
        self.sshAgentSocketPath = connection.sshConfig.agentSocketPath

        // TOTP configuration
        self.totpMode = connection.sshConfig.totpMode.rawValue
        self.totpAlgorithm = connection.sshConfig.totpAlgorithm.rawValue
        self.totpDigits = connection.sshConfig.totpDigits
        self.totpPeriod = connection.sshConfig.totpPeriod

        // SSL Configuration
        self.sslMode = connection.sslConfig.mode.rawValue
        self.sslCaCertificatePath = connection.sslConfig.caCertificatePath
        self.sslClientCertificatePath = connection.sslConfig.clientCertificatePath
        self.sslClientKeyPath = connection.sslConfig.clientKeyPath

        // Color, Tag, and Group
        self.color = connection.color.rawValue
        self.tagId = connection.tagId?.uuidString
        self.groupId = connection.groupId?.uuidString
        self.sshProfileId = connection.sshProfileId?.uuidString

        // Safe mode level
        self.safeModeLevel = connection.safeModeLevel.rawValue

        // AI policy
        self.aiPolicy = connection.aiPolicy?.rawValue
        self.aiRules = connection.aiRules
        self.aiAlwaysAllowedTools = connection.aiAlwaysAllowedTools.isEmpty
            ? nil
            : Array(connection.aiAlwaysAllowedTools).sorted()

        // MongoDB-specific
        self.mongoAuthSource = connection.mongoAuthSource
        self.mongoReadPreference = connection.mongoReadPreference
        self.mongoWriteConcern = connection.mongoWriteConcern

        // Redis-specific
        self.redisDatabase = connection.redisDatabase

        // MSSQL schema
        self.mssqlSchema = connection.mssqlSchema

        // Oracle service name
        self.oracleServiceName = connection.oracleServiceName

        // Startup commands
        self.startupCommands = connection.startupCommands

        // Sort order
        self.sortOrder = connection.sortOrder

        // Local-only
        self.localOnly = connection.localOnly

        // Sample marker
        self.isSample = connection.isSample

        // Favorite flag
        self.isFavorite = connection.isFavorite

        // SSH tunnel mode (v2 format preserving jump hosts, profiles, etc.)
        self.sshTunnelModeJson = try? JSONEncoder().encode(connection.sshTunnelMode)

        // Cloudflare tunnel mode (only persisted when enabled)
        self.cloudflareTunnelModeJson = connection.isCloudflareEnabled
            ? (try? JSONEncoder().encode(connection.cloudflareTunnelMode))
            : nil

        // Plugin-driven additional fields
        self.additionalFields = connection.additionalFields.isEmpty ? nil : connection.additionalFields

        // Password source (not synced to iCloud; see SyncRecordMapper)
        self.passwordSource = connection.passwordSource
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, type
        case sshEnabled, sshHost, sshPort, sshUsername, sshAuthMethod, sshPrivateKeyPath
        case sshAgentSocketPath
        case totpMode, totpAlgorithm, totpDigits, totpPeriod
        case sslMode, sslCaCertificatePath, sslClientCertificatePath, sslClientKeyPath
        case color, tagId, groupId, sshProfileId
        case safeModeLevel
        case isReadOnly // Legacy key for migration reading only
        case aiPolicy
        case aiRules
        case aiAlwaysAllowedTools
        case mongoAuthSource, mongoReadPreference, mongoWriteConcern, redisDatabase
        case mssqlSchema, oracleServiceName, startupCommands, sortOrder
        case sshTunnelModeJson
        case cloudflareTunnelModeJson
        case additionalFields
        case localOnly
        case isSample
        case isFavorite
        case passwordSource
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(database, forKey: .database)
        try container.encode(username, forKey: .username)
        try container.encode(type, forKey: .type)
        try container.encode(sshEnabled, forKey: .sshEnabled)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encodeIfPresent(sshPort, forKey: .sshPort)
        try container.encode(sshUsername, forKey: .sshUsername)
        try container.encode(sshAuthMethod, forKey: .sshAuthMethod)
        try container.encode(sshPrivateKeyPath, forKey: .sshPrivateKeyPath)
        try container.encode(sshAgentSocketPath, forKey: .sshAgentSocketPath)
        try container.encode(totpMode, forKey: .totpMode)
        try container.encode(totpAlgorithm, forKey: .totpAlgorithm)
        try container.encode(totpDigits, forKey: .totpDigits)
        try container.encode(totpPeriod, forKey: .totpPeriod)
        try container.encode(sslMode, forKey: .sslMode)
        try container.encode(sslCaCertificatePath, forKey: .sslCaCertificatePath)
        try container.encode(sslClientCertificatePath, forKey: .sslClientCertificatePath)
        try container.encode(sslClientKeyPath, forKey: .sslClientKeyPath)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(tagId, forKey: .tagId)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        try container.encodeIfPresent(sshProfileId, forKey: .sshProfileId)
        try container.encode(safeModeLevel, forKey: .safeModeLevel)
        try container.encodeIfPresent(aiPolicy, forKey: .aiPolicy)
        try container.encodeIfPresent(aiRules, forKey: .aiRules)
        try container.encodeIfPresent(aiAlwaysAllowedTools, forKey: .aiAlwaysAllowedTools)
        try container.encodeIfPresent(redisDatabase, forKey: .redisDatabase)
        try container.encodeIfPresent(startupCommands, forKey: .startupCommands)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(sshTunnelModeJson, forKey: .sshTunnelModeJson)
        try container.encodeIfPresent(cloudflareTunnelModeJson, forKey: .cloudflareTunnelModeJson)
        try container.encodeIfPresent(additionalFields, forKey: .additionalFields)
        try container.encode(localOnly, forKey: .localOnly)
        try container.encode(isSample, forKey: .isSample)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(passwordSource, forKey: .passwordSource)
    }

    // Custom decoder to handle migration from old format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        type = try container.decode(String.self, forKey: .type)

        sshEnabled = try container.decode(Bool.self, forKey: .sshEnabled)
        sshHost = try container.decode(String.self, forKey: .sshHost)
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort)
        sshUsername = try container.decode(String.self, forKey: .sshUsername)
        sshAuthMethod = try container.decode(String.self, forKey: .sshAuthMethod)
        sshPrivateKeyPath = try container.decode(String.self, forKey: .sshPrivateKeyPath)
        sshAgentSocketPath = try container.decodeIfPresent(String.self, forKey: .sshAgentSocketPath) ?? ""

        // TOTP configuration (migration: use defaults if missing)
        totpMode = try container.decodeIfPresent(String.self, forKey: .totpMode) ?? TOTPMode.none.rawValue
        totpAlgorithm = try container.decodeIfPresent(
            String.self, forKey: .totpAlgorithm
        ) ?? TOTPAlgorithm.sha1.rawValue
        let decodedDigits = try container.decodeIfPresent(Int.self, forKey: .totpDigits) ?? 6
        totpDigits = max(6, min(8, decodedDigits))
        let decodedPeriod = try container.decodeIfPresent(Int.self, forKey: .totpPeriod) ?? 30
        totpPeriod = max(15, min(120, decodedPeriod))

        // SSL Configuration (migration: use defaults if missing)
        sslMode = try container.decodeIfPresent(String.self, forKey: .sslMode) ?? SSLMode.disabled.rawValue
        sslCaCertificatePath = try container.decodeIfPresent(String.self, forKey: .sslCaCertificatePath) ?? ""
        sslClientCertificatePath = try container.decodeIfPresent(
            String.self, forKey: .sslClientCertificatePath
        ) ?? ""
        sslClientKeyPath = try container.decodeIfPresent(String.self, forKey: .sslClientKeyPath) ?? ""

        // Migration: use defaults if fields are missing
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ConnectionColor.none.rawValue
        tagId = try container.decodeIfPresent(String.self, forKey: .tagId)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        sshProfileId = try container.decodeIfPresent(String.self, forKey: .sshProfileId)
        // Migration: read new safeModeLevel first, fall back to old isReadOnly boolean
        if let levelString = try container.decodeIfPresent(String.self, forKey: .safeModeLevel) {
            safeModeLevel = levelString
        } else {
            let wasReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
            safeModeLevel = wasReadOnly ? SafeModeLevel.readOnly.rawValue : SafeModeLevel.silent.rawValue
        }
        aiPolicy = try container.decodeIfPresent(String.self, forKey: .aiPolicy)
        aiRules = try container.decodeIfPresent(String.self, forKey: .aiRules)
        aiAlwaysAllowedTools = try container.decodeIfPresent([String].self, forKey: .aiAlwaysAllowedTools)
        mongoAuthSource = try container.decodeIfPresent(String.self, forKey: .mongoAuthSource)
        mongoReadPreference = try container.decodeIfPresent(String.self, forKey: .mongoReadPreference)
        mongoWriteConcern = try container.decodeIfPresent(String.self, forKey: .mongoWriteConcern)
        redisDatabase = try container.decodeIfPresent(Int.self, forKey: .redisDatabase)
        mssqlSchema = try container.decodeIfPresent(String.self, forKey: .mssqlSchema)
        oracleServiceName = try container.decodeIfPresent(String.self, forKey: .oracleServiceName)
        startupCommands = try container.decodeIfPresent(String.self, forKey: .startupCommands)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        sshTunnelModeJson = try container.decodeIfPresent(Data.self, forKey: .sshTunnelModeJson)
        cloudflareTunnelModeJson = try container.decodeIfPresent(Data.self, forKey: .cloudflareTunnelModeJson)
        additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields)
        passwordSource = PasswordSource.resilientlyDecoded(from: container, forKey: .passwordSource)
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        isSample = try container.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func toConnection() -> DatabaseConnection {
        var sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: sshPort,
            username: sshUsername,
            authMethod: SSHAuthMethod(rawValue: sshAuthMethod) ?? .password,
            privateKeyPath: sshPrivateKeyPath,
            agentSocketPath: sshAgentSocketPath
        )
        sshConfig.totpMode = TOTPMode(rawValue: totpMode) ?? .none
        sshConfig.totpAlgorithm = TOTPAlgorithm(rawValue: totpAlgorithm) ?? .sha1
        sshConfig.totpDigits = totpDigits
        sshConfig.totpPeriod = totpPeriod

        // Prefer sshTunnelModeJson (v2 format) over legacy flat fields
        let resolvedTunnelMode: SSHTunnelMode
        if let json = sshTunnelModeJson,
           let decoded = try? JSONDecoder().decode(SSHTunnelMode.self, from: json) {
            resolvedTunnelMode = decoded
            switch decoded {
            case .disabled:
                break
            case .inline(let config):
                sshConfig = config
            case .profile(_, let snapshot):
                sshConfig = snapshot
            }
        } else {
            resolvedTunnelMode = .disabled
        }

        let resolvedCloudflareMode: CloudflareTunnelMode
        if let json = cloudflareTunnelModeJson,
           let decoded = try? JSONDecoder().decode(CloudflareTunnelMode.self, from: json) {
            resolvedCloudflareMode = decoded
        } else {
            resolvedCloudflareMode = .disabled
        }

        var resolvedSSLCaPath = sslCaCertificatePath
        if type == "Cassandra", resolvedSSLCaPath.isEmpty,
           let legacy = additionalFields?["sslCaCertPath"], !legacy.isEmpty {
            resolvedSSLCaPath = legacy
        }

        let sslConfig = SSLConfiguration(
            mode: SSLMode(rawValue: sslMode) ?? .disabled,
            caCertificatePath: resolvedSSLCaPath,
            clientCertificatePath: sslClientCertificatePath,
            clientKeyPath: sslClientKeyPath
        )

        let parsedColor = ConnectionColor(rawValue: color) ?? .none
        let parsedTagId = tagId.flatMap { UUID(uuidString: $0) }
        let parsedGroupId = groupId.flatMap { UUID(uuidString: $0) }
        let parsedSSHProfileId = sshProfileId.flatMap { UUID(uuidString: $0) }
        let parsedAIPolicy = aiPolicy.flatMap { AIConnectionPolicy(rawValue: $0) }

        // Merge legacy named keys into additionalFields as fallback
        let mergedFields: [String: String]? = {
            var fields = additionalFields ?? [:]
            if fields["mongoAuthSource"] == nil, let v = mongoAuthSource { fields["mongoAuthSource"] = v }
            if fields["mongoReadPreference"] == nil, let v = mongoReadPreference {
                fields["mongoReadPreference"] = v
            }
            if fields["mongoWriteConcern"] == nil, let v = mongoWriteConcern {
                fields["mongoWriteConcern"] = v
            }
            if fields["mssqlSchema"] == nil, let v = mssqlSchema { fields["mssqlSchema"] = v }
            if fields["oracleServiceName"] == nil, let v = oracleServiceName {
                fields["oracleServiceName"] = v
            }
            return fields.isEmpty ? nil : fields
        }()

        return DatabaseConnection(
            id: id,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: DatabaseType(rawValue: type),
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: parsedColor,
            tagId: parsedTagId,
            groupId: parsedGroupId,
            sshProfileId: parsedSSHProfileId,
            sshTunnelMode: resolvedTunnelMode,
            cloudflareTunnelMode: resolvedCloudflareMode,
            safeModeLevel: SafeModeLevel(rawValue: safeModeLevel) ?? .silent,
            aiPolicy: parsedAIPolicy,
            aiRules: aiRules,
            aiAlwaysAllowedTools: Set(aiAlwaysAllowedTools ?? []),
            redisDatabase: redisDatabase,
            startupCommands: startupCommands,
            sortOrder: sortOrder,
            localOnly: localOnly,
            isSample: isSample,
            isFavorite: isFavorite,
            passwordSource: passwordSource,
            additionalFields: mergedFields
        )
    }
}
