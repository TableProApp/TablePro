//
//  DBeaverImporter.swift
//  TablePro
//

import AppKit
import CommonCrypto
import Foundation
import os
import TableProImport
import TableProPluginKit

struct DBeaverImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DBeaverImporter")

    let id = "dbeaver"
    let displayName = "DBeaver"
    let symbolName = "bird"
    let appBundleIdentifier = "org.jkiss.dbeaver.core.product"
    let readsPasswordsFromKeychain = false

    /// All known DBeaver product identifiers. Community, Enterprise, Ultimate,
    /// and Lite variants each register a different bundle ID, but they all
    /// write to the same `~/Library/DBeaverData/workspace*`.
    private static let knownBundleIdentifiers = [
        "org.jkiss.dbeaver.core.product",
        "org.jkiss.dbeaver.ee.core.product",
        "org.jkiss.dbeaver.ue.product",
        "org.jkiss.dbeaver.lite.product",
        "com.dbeaver.product.ultimate"
    ]

    /// Root directory containing DBeaver workspace folders. The actual
    /// workspace path is discovered by scanning for `workspace*` subdirs so
    /// future versions (workspace7, etc.) keep working without code changes.
    var dbeaverDataRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DBeaverData")

    var resolveAppURL: (_ bundleIdentifier: String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }

    func installedAppURL() -> URL? {
        for bundleId in Self.knownBundleIdentifiers {
            if let url = resolveAppURL(bundleId) {
                return url
            }
        }
        return nil
    }

    func isAvailable() -> Bool {
        installedAppURL() != nil || findDataSourcesFile() != nil
    }

    func connectionCount() -> Int {
        guard let url = findDataSourcesFile(),
              let json = loadJSON(from: url),
              let connections = json["connections"] as? [String: Any] else { return 0 }
        return connections.count
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        guard let dataSourcesURL = findDataSourcesFile() else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        guard let json = loadJSON(from: dataSourcesURL) else {
            throw ForeignAppImportError.parseError("Could not parse data-sources.json")
        }

        guard let connectionsDict = json["connections"] as? [String: [String: Any]] else {
            throw ForeignAppImportError.unsupportedFormat("Missing connections key in data-sources.json")
        }

        let foldersDict = json["folders"] as? [String: [String: Any]] ?? [:]

        let credentialsURL = dataSourcesURL.deletingLastPathComponent()
            .appendingPathComponent("credentials-config.json")
        let credentialsMap = loadCredentials(from: credentialsURL)

        var exportableConnections: [ExportableConnection] = []
        var groupNames: Set<String> = []
        var credentials: [String: ExportableCredentials] = [:]

        for (connId, connDict) in connectionsDict {
            do {
                let credentialUsername = (credentialsMap[connId]?["#connection"] as? [String: Any])?["user"] as? String
                let conn = try parseConnection(
                    connId, dict: connDict, folders: foldersDict, credentialUsername: credentialUsername
                )
                let index = exportableConnections.count
                exportableConnections.append(conn)

                if let groupName = conn.groupName {
                    groupNames.insert(groupName)
                }

                if includePasswords, let connCreds = credentialsMap[connId] {
                    let creds = extractCredentials(from: connCreds)
                    if creds.password != nil || creds.sshPassword != nil {
                        credentials[String(index)] = creds
                    }
                }
            } catch {
                Self.logger.warning("Skipping DBeaver connection \(connId): \(error.localizedDescription)")
            }
        }

        guard !exportableConnections.isEmpty else {
            throw ForeignAppImportError.noConnectionsFound
        }

        let groups: [ExportableGroup]? = groupNames.isEmpty ? nil : groupNames.map {
            ExportableGroup(name: $0, color: nil)
        }

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "DBeaver Import",
            connections: exportableConnections,
            groups: groups,
            tags: nil,
            credentials: credentials.isEmpty ? nil : credentials
        )

        return ForeignAppImportResult(envelope: envelope, sourceName: displayName)
    }

    // MARK: - File Discovery

    /// Scans `~/Library/DBeaverData/workspace*` for a project folder that
    /// contains `.dbeaver/data-sources.json`. Supports any workspace version
    /// (workspace6, workspace7, ...) by enumeration rather than hardcoding.
    private func findDataSourcesFile() -> URL? {
        let fm = FileManager.default
        guard let workspaceDirs = try? fm.contentsOfDirectory(
            at: dbeaverDataRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let workspaces = workspaceDirs
            .filter { $0.lastPathComponent.hasPrefix("workspace") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for workspace in workspaces {
            guard let projects = try? fm.contentsOfDirectory(atPath: workspace.path) else { continue }
            for projectName in projects {
                let candidate = workspace
                    .appendingPathComponent(projectName)
                    .appendingPathComponent(".dbeaver/data-sources.json")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func loadJSON(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - Connection Parsing

    private func parseConnection(
        _ connId: String,
        dict: [String: Any],
        folders: [String: [String: Any]],
        credentialUsername: String?
    ) throws -> ExportableConnection {
        let name = dict["name"] as? String ?? connId
        let provider = dict["provider"] as? String ?? ""
        let dbType = mapProvider(provider)

        let config = dict["configuration"] as? [String: Any] ?? [:]
        let host = config["host"] as? String ?? "localhost"
        let port: Int
        if let intPort = config["port"] as? Int {
            port = intPort
        } else if let strPort = config["port"] as? String, let parsed = Int(strPort) {
            port = parsed
        } else {
            port = defaultPort(for: dbType)
        }
        let database = config["database"] as? String ?? config["url"] as? String ?? ""
        let username = [credentialUsername, config["user"] as? String]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""

        let folderPath = dict["folder"] as? String
        let groupName: String?
        if let path = folderPath, !path.isEmpty {
            if let folderInfo = folders[path], let desc = folderInfo["description"] as? String, !desc.isEmpty {
                groupName = desc
            } else {
                groupName = path.components(separatedBy: "/").last
            }
        } else {
            groupName = nil
        }

        let sshConfig = parseSSHConfig(config)
        let sslConfig = parseSSLConfig(config)
        let color = parseColor(config)

        return ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: dbType,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: color,
            tagName: nil,
            groupName: groupName,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
    }

    private func parseSSHConfig(_ config: [String: Any]) -> ExportableSSHConfig? {
        guard let handlers = config["handlers"] as? [String: Any],
              let sshTunnel = handlers["ssh_tunnel"] as? [String: Any] else { return nil }

        let properties = sshTunnel["properties"] as? [String: Any] ?? [:]

        let enabled = sshTunnel["enabled"] as? Bool ?? (properties["host"] != nil)
        guard enabled else { return nil }

        let host = properties["host"] as? String ?? ""
        let port: Int?
        if let intPort = properties["port"] as? Int {
            port = intPort
        } else if let strPort = properties["port"] as? String, let parsed = Int(strPort) {
            port = parsed
        } else {
            port = nil
        }
        let username = properties["username"] as? String ?? ""
        let authType = properties["authType"] as? String ?? "PASSWORD"
        let rawKeyPath = properties["keyPath"] as? String ?? ""
        let keyPath = ForeignAppPathHelper.resolveKeyPath(rawKeyPath)

        let authMethod: String
        switch authType {
        case "PUBLIC_KEY": authMethod = "Private Key"
        case "AGENT": authMethod = "SSH Agent"
        default: authMethod = "Password"
        }

        return ExportableSSHConfig(
            enabled: true,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            privateKeyPath: authType == "PUBLIC_KEY" ? keyPath : "",
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private func parseSSLConfig(_ config: [String: Any]) -> ExportableSSLConfig? {
        guard let handlers = config["handlers"] as? [String: Any],
              let sslHandler = handlers["ssl"] as? [String: Any] else { return nil }

        let enabled = sslHandler["enabled"] as? Bool ?? false
        guard enabled else { return nil }

        let properties = sslHandler["properties"] as? [String: Any] ?? [:]

        let mode: String
        switch properties["sslMode"] as? String ?? "" {
        case "require": mode = SSLMode.required.rawValue
        case "verify-ca": mode = SSLMode.verifyCa.rawValue
        case "verify-full": mode = SSLMode.verifyIdentity.rawValue
        default: mode = SSLMode.preferred.rawValue
        }

        let caCertPath = properties["caCertPath"] as? String
        let clientCertPath = properties["clientCertPath"] as? String
        let clientKeyPath = properties["clientKeyPath"] as? String

        return ExportableSSLConfig(
            mode: mode,
            caCertificatePath: caCertPath,
            clientCertificatePath: clientCertPath,
            clientKeyPath: clientKeyPath
        )
    }

    private func parseColor(_ config: [String: Any]) -> String? {
        guard let colorString = config["color"] as? String, !colorString.isEmpty else { return nil }
        // DBeaver stores colors as comma-separated RGB values like "255,0,0"
        let components = colorString.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count >= 3 else { return nil }
        let (r, g, b) = (components[0], components[1], components[2])

        if r > 200 && g < 100 && b < 100 { return "Red" }
        if r > 200 && g > 100 && g < 200 && b < 100 { return "Orange" }
        if r > 200 && g > 200 && b < 100 { return "Yellow" }
        if r < 100 && g > 150 && b < 100 { return "Green" }
        if r < 100 && g < 100 && b > 200 { return "Blue" }
        if r > 100 && g < 100 && b > 150 { return "Purple" }
        return nil
    }

    // MARK: - Credentials

    private static let aesKey: [UInt8] = [
        0xBA, 0xBB, 0x4A, 0x9F, 0x77, 0x4A, 0xB8, 0x53,
        0xC9, 0x6C, 0x2D, 0x65, 0x3D, 0xFE, 0x54, 0x4A
    ]

    private func loadCredentials(from url: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let decrypted = decryptCredentials(data) else { return [:] }

        guard let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else { return [:] }
        return json.compactMapValues { $0 as? [String: Any] }
    }

    private func decryptCredentials(_ data: Data) -> Data? {
        guard data.count > 16 else { return nil }

        let iv = Array(data.prefix(16))
        let ciphertext = Array(data.suffix(from: 16))

        var decryptedBytes = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            Self.aesKey,
            Self.aesKey.count,
            iv,
            ciphertext,
            ciphertext.count,
            &decryptedBytes,
            decryptedBytes.count,
            &decryptedLength
        )

        guard status == kCCSuccess else {
            Self.logger.warning("DBeaver credential decryption failed with status \(status)")
            return nil
        }

        return Data(decryptedBytes.prefix(decryptedLength))
    }

    private func extractCredentials(from connCreds: [String: Any]) -> ExportableCredentials {
        let connectionBlock = connCreds["#connection"] as? [String: Any] ?? [:]
        let password = connectionBlock["password"] as? String

        let sshBlock = connCreds["ssh_tunnel"] as? [String: Any] ?? [:]
        let sshPassword = sshBlock["password"] as? String

        return ExportableCredentials(
            password: password,
            sshPassword: sshPassword,
            keyPassphrase: nil,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    // MARK: - Mapping

    private func mapProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "mysql": return "MySQL"
        case "postgresql": return "PostgreSQL"
        case "sqlite": return "SQLite"
        case "sqlserver": return "SQL Server"
        case "oracle": return "Oracle"
        case "mongo", "mongodb": return "MongoDB"
        case "redis": return "Redis"
        case "clickhouse": return "ClickHouse"
        case "mariadb": return "MariaDB"
        case "cassandra": return "Cassandra"
        default: return provider
        }
    }

    private func defaultPort(for dbType: String) -> Int {
        switch dbType {
        case "MySQL", "MariaDB": return 3_306
        case "PostgreSQL": return 5_432
        case "MongoDB": return 27_017
        case "Redis": return 6_379
        case "SQL Server": return 1_433
        case "Oracle": return 1_521
        case "ClickHouse": return 8_123
        case "Cassandra": return 9_042
        default: return 0
        }
    }
}
