//
//  DatabaseConnection.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - SSH Configuration


/// Represents the type of database
struct DatabaseType: Hashable, Identifiable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }
    var displayName: String { rawValue }
}

extension DatabaseType {
    // Built-in types (bundled plugins)
    static let mysql = DatabaseType(rawValue: "MySQL")
    static let mariadb = DatabaseType(rawValue: "MariaDB")
    static let postgresql = DatabaseType(rawValue: "PostgreSQL")
    static let sqlite = DatabaseType(rawValue: "SQLite")
    static let redshift = DatabaseType(rawValue: "Redshift")

    // Registry-distributed types (known plugins, downloadable separately)
    static let mongodb = DatabaseType(rawValue: "MongoDB")
    static let redis = DatabaseType(rawValue: "Redis")
    static let mssql = DatabaseType(rawValue: "SQL Server")
    static let oracle = DatabaseType(rawValue: "Oracle")
    static let clickhouse = DatabaseType(rawValue: "ClickHouse")
    static let duckdb = DatabaseType(rawValue: "DuckDB")
    static let cassandra = DatabaseType(rawValue: "Cassandra")
    static let scylladb = DatabaseType(rawValue: "ScyllaDB")
    static let etcd = DatabaseType(rawValue: "etcd")
    static let cloudflareD1 = DatabaseType(rawValue: "Cloudflare D1")
    static let dynamodb = DatabaseType(rawValue: "DynamoDB")
    static let bigQuery = DatabaseType(rawValue: "BigQuery")
}

extension DatabaseType: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension DatabaseType {
    /// All registered database types, derived dynamically from the plugin metadata registry.
    static var allKnownTypes: [DatabaseType] {
        PluginMetadataRegistry.shared.allRegisteredTypeIds().map { DatabaseType(rawValue: $0) }
    }

    /// Compatibility shim for CaseIterable call sites.
    static var allCases: [DatabaseType] { allKnownTypes }
}

extension DatabaseType {
    /// Returns nil if rawValue doesn't match any registered type.
    init?(validating rawValue: String) {
        guard PluginMetadataRegistry.shared.hasType(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

extension DatabaseType {
    /// Plugin type ID used for PluginManager lookup, resolved via the registry.
    var pluginTypeId: String {
        PluginMetadataRegistry.shared.pluginTypeId(for: rawValue)
    }

    var isDownloadablePlugin: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.isDownloadable ?? false
    }

    var iconName: String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.iconName ?? "database-icon"
    }

    /// Returns the correct SwiftUI Image for this database type, handling both
    /// SF Symbol names (e.g. "cylinder.fill") and asset catalog names (e.g. "mysql-icon").
    var iconImage: Image {
        let name = iconName
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return Image(systemName: name)
        }
        return Image(name).resizable()
    }

    var defaultPort: Int {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.defaultPort ?? 0
    }

    var requiresAuthentication: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.requiresAuthentication ?? true
    }

    var supportsForeignKeys: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.supportsForeignKeys ?? true
    }

    var supportsSchemaEditing: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.supportsSchemaEditing ?? true
    }

    var supportsAddColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsAddColumn ?? true
    }

    var supportsModifyColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsModifyColumn ?? true
    }

    var supportsDropColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsDropColumn ?? true
    }

    var supportsRenameColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsRenameColumn ?? false
    }

    var supportsAddIndex: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsAddIndex ?? true
    }

    var supportsDropIndex: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsDropIndex ?? true
    }

    var supportsModifyPrimaryKey: Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: pluginTypeId)?.capabilities.supportsModifyPrimaryKey ?? true
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
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .gray: return Color(nsColor: .systemGray)
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
    var safeModeLevel: SafeModeLevel
    var aiPolicy: AIConnectionPolicy?
    var additionalFields: [String: String] = [:]
    var redisDatabase: Int?
    var startupCommands: String?
    var sortOrder: Int

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
        safeModeLevel: SafeModeLevel = .silent,
        aiPolicy: AIConnectionPolicy? = nil,
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
        self.aiPolicy = aiPolicy
        self.redisDatabase = redisDatabase
        self.startupCommands = startupCommands
        self.sortOrder = sortOrder
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

// MARK: - Codable Conformance

extension DatabaseConnection: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, type
        case sshConfig, sslConfig, color, tagId, groupId, sshProfileId
        case sshTunnelMode, safeModeLevel, aiPolicy, additionalFields
        case redisDatabase, startupCommands, sortOrder
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
        additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields) ?? [:]
        redisDatabase = try container.decodeIfPresent(Int.self, forKey: .redisDatabase)
        startupCommands = try container.decodeIfPresent(String.self, forKey: .startupCommands)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0

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
        try container.encode(safeModeLevel, forKey: .safeModeLevel)
        try container.encodeIfPresent(aiPolicy, forKey: .aiPolicy)
        try container.encode(additionalFields, forKey: .additionalFields)
        try container.encodeIfPresent(redisDatabase, forKey: .redisDatabase)
        try container.encodeIfPresent(startupCommands, forKey: .startupCommands)
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}

// MARK: - String Helpers

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
