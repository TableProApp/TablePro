//
//  ConnectionExport.swift
//  TablePro
//

import Foundation
import UniformTypeIdentifiers

// MARK: - UTType

extension UTType {
    // swiftlint:disable:next force_unwrapping
    static let tableproConnectionShare = UTType("com.tablepro.connection-share")!
}

// MARK: - Export Envelope

struct ConnectionExportEnvelope: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String
    let connections: [ExportableConnection]
    let groups: [ExportableGroup]?
    let tags: [ExportableTag]?
    let credentials: [String: ExportableCredentials]? // keyed by connection index "0", "1", ...
}

// MARK: - Exportable Connection

struct ExportableConnection: Codable {
    let name: String
    let host: String
    let port: Int
    let database: String
    let username: String
    let type: String
    let sshConfig: ExportableSSHConfig?
    let sslConfig: ExportableSSLConfig?
    let color: String?
    let tagName: String?
    let groupName: String?
    let sshProfileId: String?
    let safeModeLevel: String?
    let aiPolicy: String?
    let additionalFields: [String: String]?
    let redisDatabase: Int?
    let startupCommands: String?
    let localOnly: Bool?

    func renamed(to newName: String) -> ExportableConnection {
        ExportableConnection(
            name: newName, host: host, port: port, database: database,
            username: username, type: type, sshConfig: sshConfig,
            sslConfig: sslConfig, color: color, tagName: tagName,
            groupName: groupName, sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel, aiPolicy: aiPolicy,
            additionalFields: additionalFields, redisDatabase: redisDatabase,
            startupCommands: startupCommands, localOnly: localOnly
        )
    }

    /// One-line subtitle for connection rows. File-based databases
    /// (SQLite, DuckDB) show the database path; everything else shows
    /// `host:port`.
    var displaySubtitle: String {
        if type == "SQLite" || type == "DuckDB" {
            return database.isEmpty
                ? type
                : (database as NSString).abbreviatingWithTildeInPath
        }
        return "\(host):\(port)"
    }
}

extension ExportableConnection {
    static let importBlockedAdditionalFieldKeys: Set<String> = ["preConnectScript"]

    func sanitizedForImport() -> ExportableConnection {
        guard let additionalFields else { return self }
        let allowed = additionalFields.filter { !Self.importBlockedAdditionalFieldKeys.contains($0.key) }
        guard allowed.count != additionalFields.count else { return self }
        return ExportableConnection(
            name: name, host: host, port: port, database: database,
            username: username, type: type, sshConfig: sshConfig,
            sslConfig: sslConfig, color: color, tagName: tagName,
            groupName: groupName, sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel, aiPolicy: aiPolicy,
            additionalFields: allowed.isEmpty ? nil : allowed, redisDatabase: redisDatabase,
            startupCommands: startupCommands, localOnly: localOnly
        )
    }
}

// MARK: - SSH Config

struct ExportableSSHConfig: Codable {
    let enabled: Bool
    let host: String
    let port: Int?
    let username: String
    let authMethod: String
    let privateKeyPath: String
    let agentSocketPath: String
    let jumpHosts: [ExportableJumpHost]?
    let totpMode: String?
    let totpAlgorithm: String?
    let totpDigits: Int?
    let totpPeriod: Int?
}

struct ExportableJumpHost: Codable {
    let host: String
    let port: Int?
    let username: String
    let authMethod: String
    let privateKeyPath: String
}

// MARK: - SSL Config

struct ExportableSSLConfig: Codable {
    let mode: String
    let caCertificatePath: String?
    let clientCertificatePath: String?
    let clientKeyPath: String?
}

// MARK: - Group & Tag

struct ExportableGroup: Codable {
    let name: String
    let color: String?
}

struct ExportableTag: Codable {
    let name: String
    let color: String?
}

// MARK: - Credentials (encrypted export only)

struct ExportableCredentials: Codable {
    let password: String?
    let sshPassword: String?
    let keyPassphrase: String?
    let sslClientKeyPassphrase: String?
    let totpSecret: String?
    let pluginSecureFields: [String: String]?
}

// MARK: - Path Portability

enum PathPortability {
    static func contractHome(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
}
