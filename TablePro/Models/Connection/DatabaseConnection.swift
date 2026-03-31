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

/// SSH authentication method
enum SSHAuthMethod: String, CaseIterable, Identifiable, Codable {
    case password = "Password"
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"
    case keyboardInteractive = "Keyboard Interactive"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .privateKey: return String(localized: "Private Key")
        case .sshAgent: return String(localized: "SSH Agent")
        case .keyboardInteractive: return String(localized: "Keyboard Interactive")
        }
    }

    var iconName: String {
        switch self {
        case .password: return "key.fill"
        case .privateKey: return "doc.text.fill"
        case .sshAgent: return "person.badge.key.fill"
        case .keyboardInteractive: return "lock.rotation"
        }
    }
}

enum SSHAgentSocketOption: String, CaseIterable, Identifiable {
    case systemDefault
    case onePassword
    case custom

    static let onePasswordSocketPath = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    private static let onePasswordAliasPath = "~/.1password/agent.sock"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault:
            return "SSH_AUTH_SOCK"
        case .onePassword:
            return "1Password"
        case .custom:
            return String(localized: "Custom Path")
        }
    }

    init(socketPath: String) {
        let trimmedPath = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmedPath {
        case "":
            self = .systemDefault
        case Self.onePasswordSocketPath, Self.onePasswordAliasPath:
            self = .onePassword
        default:
            self = .custom
        }
    }

    func resolvedPath(customPath: String) -> String {
        switch self {
        case .systemDefault:
            return ""
        case .onePassword:
            return Self.onePasswordSocketPath
        case .custom:
            return customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum SSHJumpAuthMethod: String, CaseIterable, Identifiable, Codable {
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"

    var id: String { rawValue }
}

struct SSHJumpHost: Codable, Hashable, Identifiable {
    var id = UUID()
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: SSHJumpAuthMethod = .sshAgent
    var privateKeyPath: String = ""

    var isValid: Bool {
        !host.isEmpty && !username.isEmpty &&
        (authMethod == .sshAgent || !privateKeyPath.isEmpty)
    }

    var proxyJumpString: String {
        "\(username)@\(host):\(port)"
    }
}

/// SSH tunnel configuration for database connections
struct SSHConfiguration: Codable, Hashable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: SSHAuthMethod = .password
    var privateKeyPath: String = ""  // Path to identity file (e.g., ~/.ssh/id_rsa)
    var useSSHConfig: Bool = true  // Auto-fill from ~/.ssh/config when selecting host
    var agentSocketPath: String = ""  // Custom SSH_AUTH_SOCK path (empty = use system default)
    var jumpHosts: [SSHJumpHost] = []
    var totpMode: TOTPMode = .none
    var totpAlgorithm: TOTPAlgorithm = .sha1
    var totpDigits: Int = 6
    var totpPeriod: Int = 30

    /// Check if SSH configuration is complete enough for connection
    var isValid: Bool {
        guard enabled else { return true }  // Not enabled = valid (skip SSH)
        guard !host.isEmpty, !username.isEmpty else { return false }

        let authValid: Bool
        switch authMethod {
        case .password:
            authValid = true
        case .privateKey:
            authValid = !privateKeyPath.isEmpty
        case .sshAgent:
            authValid = true
        case .keyboardInteractive:
            authValid = true
        }

        return authValid && jumpHosts.allSatisfy(\.isValid)
    }
}

extension SSHConfiguration {
    enum CodingKeys: String, CodingKey {
        case enabled, host, port, username, authMethod, privateKeyPath, useSSHConfig, agentSocketPath, jumpHosts
        case totpMode, totpAlgorithm, totpDigits, totpPeriod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(SSHAuthMethod.self, forKey: .authMethod)
        privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        useSSHConfig = try container.decode(Bool.self, forKey: .useSSHConfig)
        agentSocketPath = try container.decode(String.self, forKey: .agentSocketPath)
        jumpHosts = try container.decodeIfPresent([SSHJumpHost].self, forKey: .jumpHosts) ?? []
        totpMode = try container.decodeIfPresent(TOTPMode.self, forKey: .totpMode) ?? .none
        totpAlgorithm = try container.decodeIfPresent(TOTPAlgorithm.self, forKey: .totpAlgorithm) ?? .sha1
        totpDigits = try container.decodeIfPresent(Int.self, forKey: .totpDigits) ?? 6
        totpPeriod = try container.decodeIfPresent(Int.self, forKey: .totpPeriod) ?? 30
    }
}

// MARK: - SSL Configuration

/// SSL/TLS connection mode
enum SSLMode: String, CaseIterable, Identifiable, Codable {
    case disabled = "Disabled"
    case preferred = "Preferred"
    case required = "Required"
    case verifyCa = "Verify CA"
    case verifyIdentity = "Verify Identity"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .disabled: return String(localized: "No SSL encryption")
        case .preferred: return String(localized: "Use SSL if available")
        case .required: return String(localized: "Require SSL, skip verification")
        case .verifyCa: return String(localized: "Verify server certificate")
        case .verifyIdentity: return String(localized: "Verify certificate and hostname")
        }
    }
}

/// SSL/TLS configuration for database connections
struct SSLConfiguration: Codable, Hashable {
    var mode: SSLMode = .disabled
    var caCertificatePath: String = ""
    var clientCertificatePath: String = ""
    var clientKeyPath: String = ""

    /// Whether SSL is effectively enabled
    var isEnabled: Bool { mode != .disabled }

    /// Whether certificate verification is enabled
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyIdentity }
}

// MARK: - Database Type

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
    var safeModeLevel: SafeModeLevel
    var aiPolicy: AIConnectionPolicy?
    var additionalFields: [String: String] = [:]
    var redisDatabase: Int?
    var startupCommands: String?

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
        self.aiPolicy = aiPolicy
        self.redisDatabase = redisDatabase
        self.startupCommands = startupCommands
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

extension DatabaseConnection: Codable {}

// MARK: - String Helpers

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
