//
//  TablePlusImporter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

struct TablePlusImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TablePlusImporter")

    let id = "tableplus"
    let displayName = "TablePlus"
    let symbolName = "rectangle.stack"
    let appBundleIdentifier = "com.tinyapp.TablePlus"

    var connectionsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist")

    var groupsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.tinyapp.TablePlus/Data/ConnectionGroups.plist")

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: connectionsFileURL.path)
    }

    func connectionCount() -> Int {
        guard let data = try? Data(contentsOf: connectionsFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let array = plist as? [[String: Any]] else { return 0 }
        return array.count
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        guard FileManager.default.fileExists(atPath: connectionsFileURL.path) else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: connectionsFileURL)
        } catch {
            throw ForeignAppImportError.parseError(error.localizedDescription)
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = plist as? [[String: Any]] else {
            throw ForeignAppImportError.unsupportedFormat("Expected array of dictionaries in Connections.plist")
        }

        let groupMap = loadGroups()
        var exportableConnections: [ExportableConnection] = []
        var groupNames: Set<String> = []
        var credentials: [String: ExportableCredentials] = [:]
        var credentialsAborted = false

        for entry in entries {
            try Task.checkCancellation()
            do {
                let conn = try parseConnection(entry, groupMap: groupMap)
                let index = exportableConnections.count
                exportableConnections.append(conn)

                if let groupName = conn.groupName {
                    groupNames.insert(groupName)
                }

                if includePasswords, !credentialsAborted, let connId = entry["ID"] as? String {
                    let creds = readCredentials(for: connId, abortFlag: &credentialsAborted)
                    if creds.password != nil || creds.sshPassword != nil || creds.keyPassphrase != nil {
                        credentials[String(index)] = creds
                    }
                }
            } catch {
                Self.logger.warning("Skipping TablePlus connection: \(error.localizedDescription)")
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
            appVersion: "TablePlus Import",
            connections: exportableConnections,
            groups: groups,
            tags: nil,
            credentials: credentials.isEmpty ? nil : credentials
        )

        return ForeignAppImportResult(
            envelope: envelope,
            sourceName: displayName,
            credentialsAborted: credentialsAborted
        )
    }

    // MARK: - Private

    private func loadGroups() -> [String: String] {
        guard let data = try? Data(contentsOf: groupsFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let array = plist as? [[String: Any]] else { return [:] }

        var map: [String: String] = [:]
        for group in array {
            if let groupId = group["ID"] as? String,
               let name = group["Name"] as? String {
                map[groupId] = name
            }
        }
        return map
    }

    private func parseConnection(
        _ entry: [String: Any],
        groupMap: [String: String]
    ) throws -> ExportableConnection {
        guard let name = entry["ConnectionName"] as? String else {
            throw ForeignAppImportError.parseError("Missing ConnectionName")
        }

        let driverString = entry["Driver"] as? String ?? ""
        let dbType = mapDriver(driverString)

        let host = entry["DatabaseHost"] as? String ?? "localhost"
        let port: Int
        if let intPort = entry["DatabasePort"] as? Int {
            port = intPort
        } else if let strPort = entry["DatabasePort"] as? String, let parsed = Int(strPort) {
            port = parsed
        } else {
            port = defaultPort(for: dbType)
        }
        let username = entry["DatabaseUser"] as? String ?? ""
        let database: String
        if dbType == "SQLite" {
            database = entry["DatabasePath"] as? String ?? ""
        } else {
            database = entry["DatabaseName"] as? String ?? ""
        }

        let groupName: String?
        if let groupId = entry["GroupID"] as? String, !groupId.isEmpty {
            groupName = groupMap[groupId]
        } else {
            groupName = nil
        }

        let sshConfig = parseSSHConfig(entry)
        let sslConfig = parseSSLConfig(entry)
        let color = mapEnvironmentColor(entry["Enviroment"] as? String)

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

    private func parseSSHConfig(_ entry: [String: Any]) -> ExportableSSHConfig? {
        guard entry["isOverSSH"] as? Bool == true else { return nil }
        let host = entry["ServerAddress"] as? String ?? ""
        let port = (entry["ServerPort"] as? String).flatMap(Int.init)
        let username = entry["ServerUser"] as? String ?? ""
        let useKey = entry["isUsePrivateKey"] as? Bool ?? false
        let rawKeyPath = entry["ServerPrivateKeyName"] as? String ?? ""
        let keyPath = ForeignAppPathHelper.resolveKeyPath(rawKeyPath)

        return ExportableSSHConfig(
            enabled: true,
            host: host,
            port: port,
            username: username,
            authMethod: useKey ? "Private Key" : "Password",
            privateKeyPath: useKey ? keyPath : "",
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private func parseSSLConfig(_ entry: [String: Any]) -> ExportableSSLConfig? {
        guard entry.keys.contains("tLSMode") else { return nil }
        let tlsMode = entry["tLSMode"] as? Int ?? 0

        let mode: String
        switch tlsMode {
        case 0: mode = SSLMode.preferred.rawValue
        case 1: mode = SSLMode.required.rawValue
        case 2: mode = SSLMode.verifyCa.rawValue
        case 3: mode = SSLMode.verifyIdentity.rawValue
        default: return nil
        }

        let paths = entry["TlsKeyPaths"] as? [String] ?? []
        return ExportableSSLConfig(
            mode: mode,
            caCertificatePath: !paths.isEmpty ? paths[0] : nil,
            clientCertificatePath: paths.count > 1 ? paths[1] : nil,
            clientKeyPath: paths.count > 2 ? paths[2] : nil
        )
    }

    private func readCredentials(for connectionId: String, abortFlag: inout Bool) -> ExportableCredentials {
        func read(_ account: String) -> String? {
            guard !abortFlag else { return nil }
            switch ForeignKeychainReader.readPassword(service: "com.tableplus.TablePlus", account: account) {
            case .found(let value):
                return value
            case .notFound:
                return nil
            case .cancelled:
                abortFlag = true
                return nil
            }
        }

        let dbPassword = read("\(connectionId)_database")
        let sshPassword = read("\(connectionId)_server")
        let keyPassphrase = read("\(connectionId)_server_key")
        return ExportableCredentials(
            password: dbPassword,
            sshPassword: sshPassword,
            keyPassphrase: keyPassphrase,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    private func mapDriver(_ driver: String) -> String {
        switch driver {
        case "MySQL": return "MySQL"
        case "PostgreSQL": return "PostgreSQL"
        case "Mongo": return "MongoDB"
        case "SQLite": return "SQLite"
        case "Redis": return "Redis"
        case "MSSQL": return "SQL Server"
        case "Redshift": return "Redshift"
        case "MariaDB": return "MariaDB"
        case "CockroachDB": return "PostgreSQL"
        default: return driver
        }
    }

    private func defaultPort(for dbType: String) -> Int {
        switch dbType {
        case "MySQL", "MariaDB": return 3_306
        case "PostgreSQL", "Redshift": return 5_432
        case "MongoDB": return 27_017
        case "Redis": return 6_379
        case "SQL Server": return 1_433
        default: return 0
        }
    }

    private func mapEnvironmentColor(_ environment: String?) -> String? {
        switch environment {
        case "staging": return "Yellow"
        case "production": return "Red"
        case "testing": return "Blue"
        case "development": return "Green"
        default: return nil
        }
    }
}
