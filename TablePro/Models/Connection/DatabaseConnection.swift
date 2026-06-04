//
//  DatabaseConnection.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import SwiftUI
import TableProPluginKit

// MARK: - External Access

enum ExternalAccessLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case blocked
    case readOnly
    case readWrite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blocked: return String(localized: "Blocked")
        case .readOnly: return String(localized: "Read Only")
        case .readWrite: return String(localized: "Read & Write")
        }
    }

    private var rank: Int {
        switch self {
        case .blocked: 0
        case .readOnly: 1
        case .readWrite: 2
        }
    }

    func satisfies(_ required: ExternalAccessLevel) -> Bool {
        rank >= required.rank
    }
}

// MARK: - Connection Color

/// Preset colors for connection status indicators
enum ConnectionColor: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case gray = "Gray"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .gray: return String(localized: "Gray")
        }
    }

    /// SwiftUI Color for display
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    /// Whether this represents "no custom color"
    var isDefault: Bool { self == .none }
}

// MARK: - Database Connection

/// Model representing a database connection
struct DatabaseConnection: Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var type: DatabaseType
    var sshConfig: SSHConfiguration
    var sslConfig: SSLConfiguration
    var color: ConnectionColor
    var tagId: UUID?
    var groupId: UUID?
    var sshProfileId: UUID?
    var sshTunnelMode: SSHTunnelMode
    var cloudflareTunnelMode: CloudflareTunnelMode = .disabled
    var safeModeLevel: SafeModeLevel
    var aiPolicy: AIConnectionPolicy?
    var aiRules: String?
    var aiAlwaysAllowedTools: Set<String> = []
    var externalAccess: ExternalAccessLevel = .readOnly
    var additionalFields: [String: String] = [:]
    var redisDatabase: Int?
    var startupCommands: String?
    var sortOrder: Int
    var localOnly: Bool = false
    var isSample: Bool = false
    var isFavorite: Bool = false
    var passwordSource: PasswordSource?

    var mongoAuthSource: String? {
        get { additionalFields["mongoAuthSource"]?.nilIfEmpty }
        set { additionalFields["mongoAuthSource"] = newValue ?? "" }
    }

    var mongoReadPreference: String? {
        get { additionalFields["mongoReadPreference"]?.nilIfEmpty }
        set { additionalFields["mongoReadPreference"] = newValue ?? "" }
    }

    var mongoWriteConcern: String? {
        get { additionalFields["mongoWriteConcern"]?.nilIfEmpty }
        set { additionalFields["mongoWriteConcern"] = newValue ?? "" }
    }

    var mongoUseSrv: Bool {
        get { additionalFields["mongoUseSrv"] == "true" }
        set { additionalFields["mongoUseSrv"] = newValue ? "true" : "" }
    }

    var mongoAuthMechanism: String? {
        get { additionalFields["mongoAuthMechanism"]?.nilIfEmpty }
        set { additionalFields["mongoAuthMechanism"] = newValue ?? "" }
    }

    var mongoReplicaSet: String? {
        get { additionalFields["mongoReplicaSet"]?.nilIfEmpty }
        set { additionalFields["mongoReplicaSet"] = newValue ?? "" }
    }

    var mssqlSchema: String? {
        get { additionalFields["mssqlSchema"]?.nilIfEmpty }
        set { additionalFields["mssqlSchema"] = newValue ?? "" }
    }

    var oracleServiceName: String? {
        get { additionalFields["oracleServiceName"]?.nilIfEmpty }
        set { additionalFields["oracleServiceName"] = newValue ?? "" }
    }

    var usePgpass: Bool {
        get { additionalFields["usePgpass"] == "true" }
        set { additionalFields["usePgpass"] = newValue ? "true" : "" }
    }

    var promptForPassword: Bool {
        get { additionalFields["promptForPassword"] == "true" }
        set { additionalFields["promptForPassword"] = newValue ? "true" : "" }
    }

    var usesAWSIAM: Bool {
        let value = additionalFields["awsAuth"] ?? "off"
        return value != "off" && !value.isEmpty
    }

    var resolvesAWSIAMInDriver: Bool {
        type == .cassandra || type == .scylladb
    }

    var preConnectScript: String? {
        get { additionalFields["preConnectScript"]?.nilIfEmpty }
        set { additionalFields["preConnectScript"] = newValue ?? "" }
    }

    init(
        id: UUID = UUID(),
        name: String,
        host: String = "localhost",
        port: Int = 3_306,
        database: String = "",
        username: String = "root",
        type: DatabaseType = .mysql,
        sshConfig: SSHConfiguration = SSHConfiguration(),
        sslConfig: SSLConfiguration = SSLConfiguration(),
        color: ConnectionColor = .none,
        tagId: UUID? = nil,
        groupId: UUID? = nil,
        sshProfileId: UUID? = nil,
        sshTunnelMode: SSHTunnelMode = .disabled,
        cloudflareTunnelMode: CloudflareTunnelMode = .disabled,
        safeModeLevel: SafeModeLevel = .silent,
        aiPolicy: AIConnectionPolicy? = nil,
        aiRules: String? = nil,
        aiAlwaysAllowedTools: Set<String> = [],
        externalAccess: ExternalAccessLevel = .readOnly,
        mongoAuthSource: String? = nil,
        mongoReadPreference: String? = nil,
        mongoWriteConcern: String? = nil,
        mongoUseSrv: Bool = false,
        mongoAuthMechanism: String? = nil,
        mongoReplicaSet: String? = nil,
        redisDatabase: Int? = nil,
        mssqlSchema: String? = nil,
        oracleServiceName: String? = nil,
        startupCommands: String? = nil,
        sortOrder: Int = 0,
        localOnly: Bool = false,
        isSample: Bool = false,
        isFavorite: Bool = false,
        passwordSource: PasswordSource? = nil,
        additionalFields: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.type = type
        self.sshConfig = sshConfig
        self.sslConfig = sslConfig
        self.color = color
        self.tagId = tagId
        self.groupId = groupId
        self.sshProfileId = sshProfileId
        self.safeModeLevel = safeModeLevel

        // Auto-derive sshTunnelMode from legacy fields if not explicitly set
        if sshTunnelMode == .disabled {
            if let profileId = sshProfileId {
                var snapshot = sshConfig
                snapshot.enabled = true
                self.sshTunnelMode = .profile(id: profileId, snapshot: snapshot)
            } else if sshConfig.enabled {
                self.sshTunnelMode = .inline(sshConfig)
            } else {
                self.sshTunnelMode = .disabled
            }
        } else {
            self.sshTunnelMode = sshTunnelMode
        }
        self.cloudflareTunnelMode = cloudflareTunnelMode
        self.aiPolicy = aiPolicy
        self.aiRules = aiRules
        self.aiAlwaysAllowedTools = aiAlwaysAllowedTools
        self.externalAccess = externalAccess
        self.redisDatabase = redisDatabase
        self.startupCommands = startupCommands
        self.sortOrder = sortOrder
        self.localOnly = localOnly
        self.isSample = isSample
        self.isFavorite = isFavorite
        self.passwordSource = passwordSource
        if let additionalFields {
            self.additionalFields = additionalFields
        } else {
            var fields: [String: String] = [:]
            if let v = mongoAuthSource { fields["mongoAuthSource"] = v }
            if let v = mongoReadPreference { fields["mongoReadPreference"] = v }
            if let v = mongoWriteConcern { fields["mongoWriteConcern"] = v }
            if mongoUseSrv { fields["mongoUseSrv"] = "true" }
            if let v = mongoAuthMechanism { fields["mongoAuthMechanism"] = v }
            if let v = mongoReplicaSet { fields["mongoReplicaSet"] = v }
            if let v = mssqlSchema { fields["mssqlSchema"] = v }
            if let v = oracleServiceName { fields["oracleServiceName"] = v }
            self.additionalFields = fields
        }
    }

    /// Returns the display color (custom color or database type color)
    @MainActor var displayColor: Color {
        color.isDefault ? type.themeColor : color.color
    }
}

// MARK: - Preview Data

extension DatabaseConnection {
    static let preview = DatabaseConnection(name: "Preview Connection")
}

// MARK: - Display Helpers

extension DatabaseConnection {
    var hostDisplayString: String {
        if let mongoHosts = additionalFields["mongoHosts"], mongoHosts.contains(",") {
            let count = mongoHosts.split(separator: ",").count
            return String(format: String(localized: "%@ (+%d more)"), "\(host):\(port)", count - 1)
        }
        return "\(host):\(port)"
    }
}

// MARK: - Codable Conformance

extension DatabaseConnection: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, type
        case sshConfig, sslConfig, color, tagId, groupId, sshProfileId
        case sshTunnelMode, cloudflareTunnelMode, safeModeLevel, aiPolicy, aiRules, aiAlwaysAllowedTools, externalAccess, additionalFields
        case redisDatabase, startupCommands, sortOrder, localOnly, isSample, isFavorite
        case passwordSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 3_306
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? "root"
        type = try container.decodeIfPresent(DatabaseType.self, forKey: .type) ?? .mysql
        sshConfig = try container.decodeIfPresent(SSHConfiguration.self, forKey: .sshConfig) ?? SSHConfiguration()
        sslConfig = try container.decodeIfPresent(SSLConfiguration.self, forKey: .sslConfig) ?? SSLConfiguration()
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? .none
        tagId = try container.decodeIfPresent(UUID.self, forKey: .tagId)
        groupId = try container.decodeIfPresent(UUID.self, forKey: .groupId)
        sshProfileId = try container.decodeIfPresent(UUID.self, forKey: .sshProfileId)
        safeModeLevel = try container.decodeIfPresent(SafeModeLevel.self, forKey: .safeModeLevel) ?? .silent
        aiPolicy = try container.decodeIfPresent(AIConnectionPolicy.self, forKey: .aiPolicy)
        aiRules = try container.decodeIfPresent(String.self, forKey: .aiRules)
        aiAlwaysAllowedTools = try container.decodeIfPresent(Set<String>.self, forKey: .aiAlwaysAllowedTools) ?? []
        externalAccess = try container.decodeIfPresent(ExternalAccessLevel.self, forKey: .externalAccess) ?? .readOnly
        additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields) ?? [:]
        redisDatabase = try container.decodeIfPresent(Int.self, forKey: .redisDatabase)
        startupCommands = try container.decodeIfPresent(String.self, forKey: .startupCommands)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        isSample = try container.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        passwordSource = PasswordSource.resilientlyDecoded(from: container, forKey: .passwordSource)
        cloudflareTunnelMode = try container.decodeIfPresent(CloudflareTunnelMode.self, forKey: .cloudflareTunnelMode) ?? .disabled

        // Migrate from legacy fields if sshTunnelMode is not present
        if let tunnelMode = try container.decodeIfPresent(SSHTunnelMode.self, forKey: .sshTunnelMode) {
            sshTunnelMode = tunnelMode
        } else {
            if let profileId = sshProfileId {
                var snapshot = sshConfig
                snapshot.enabled = true
                sshTunnelMode = .profile(id: profileId, snapshot: snapshot)
            } else if sshConfig.enabled {
                sshTunnelMode = .inline(sshConfig)
            } else {
                sshTunnelMode = .disabled
            }
        }
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
        try container.encode(sshConfig, forKey: .sshConfig)
        try container.encode(sslConfig, forKey: .sslConfig)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(tagId, forKey: .tagId)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        try container.encodeIfPresent(sshProfileId, forKey: .sshProfileId)
        try container.encode(sshTunnelMode, forKey: .sshTunnelMode)
        if case .inline = cloudflareTunnelMode {
            try container.encode(cloudflareTunnelMode, forKey: .cloudflareTunnelMode)
        }
        try container.encode(safeModeLevel, forKey: .safeModeLevel)
        try container.encodeIfPresent(aiPolicy, forKey: .aiPolicy)
        try container.encodeIfPresent(aiRules, forKey: .aiRules)
        if !aiAlwaysAllowedTools.isEmpty {
            try container.encode(aiAlwaysAllowedTools, forKey: .aiAlwaysAllowedTools)
        }
        try container.encode(externalAccess, forKey: .externalAccess)
        try container.encode(additionalFields, forKey: .additionalFields)
        try container.encodeIfPresent(redisDatabase, forKey: .redisDatabase)
        try container.encodeIfPresent(startupCommands, forKey: .startupCommands)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(localOnly, forKey: .localOnly)
        try container.encode(isSample, forKey: .isSample)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(passwordSource, forKey: .passwordSource)
    }
}

// MARK: - String Helpers

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
