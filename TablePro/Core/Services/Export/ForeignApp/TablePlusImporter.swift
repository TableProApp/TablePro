//
//  TablePlusImporter.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProImport
import TableProPluginKit

struct TablePlusImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TablePlusImporter")

    let id = "tableplus"
    let displayName = "TablePlus"
    let symbolName = "rectangle.stack"
    let appBundleIdentifier = "com.tinyapp.TablePlus"
    let readsPasswordsFromKeychain = true

    static let keychainService = "com.tableplus.TablePlus"

    private static let knownBundleIdentifiers = [
        "com.tinyapp.TablePlus",
        "com.tinyapp.TablePlus-setapp"
    ]

    var readKeychain: ForeignKeychainRead = ForeignKeychainReader.readPassword
    var keyFileExists: @Sendable (_ path: String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var resolveAppURL: @Sendable (_ bundleIdentifier: String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }

    var dataDirectoryOverride: URL?

    var connectionsFileURL: URL {
        dataDirectory.appendingPathComponent("Connections.plist")
    }

    var groupsFileURL: URL {
        dataDirectory.appendingPathComponent("ConnectionGroups.plist")
    }

    func installedAppURL() -> URL? {
        installedBundleIdentifier.flatMap { resolveAppURL($0) }
    }

    private var installedBundleIdentifier: String? {
        Self.knownBundleIdentifiers.first { resolveAppURL($0) != nil }
    }

    private var dataDirectory: URL {
        if let dataDirectoryOverride {
            return dataDirectoryOverride
        }
        return Self.dataDirectory(
            forBundleIdentifier: installedBundleIdentifier ?? appBundleIdentifier,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func dataDirectory(forBundleIdentifier bundleIdentifier: String, home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/\(bundleIdentifier)/Data")
    }

    func connectionCount() -> Int {
        guard let data = try? Data(contentsOf: connectionsFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let array = plist as? [[String: Any]] else { return 0 }
        return array.count
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        let connectionsURL = connectionsFileURL
        guard FileManager.default.fileExists(atPath: connectionsURL.path) else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: connectionsURL)
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
                    let creds = readCredentials(
                        for: connId,
                        databaseMode: TablePlusPasswordMode.resolve(entry["DatabasePasswordMode"]),
                        serverMode: TablePlusPasswordMode.resolve(entry["ServerPasswordMode"]),
                        abortFlag: &credentialsAborted
                    )
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

        let driver = entry["Driver"] as? String ?? ""
        let dbType = Self.databaseType(forDriver: driver)
        let filePathField = ForeignAppDatabaseType.localFilePathField(for: dbType)
        let filePath = filePathField == nil ? nil : (entry["DatabasePath"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let host = entry["DatabaseHost"] as? String ?? "localhost"
        let port: Int
        if let intPort = entry["DatabasePort"] as? Int {
            port = intPort
        } else if let strPort = entry["DatabasePort"] as? String, let parsed = Int(strPort) {
            port = parsed
        } else {
            port = filePath == nil ? ForeignAppDatabaseType.defaultPort(for: dbType) : 0
        }
        let username = entry["DatabaseUser"] as? String ?? ""
        let database: String
        var additionalFields: [String: String] = [:]
        switch (filePath, filePathField) {
        case (let path?, .database?):
            database = path
        case (let path?, .additionalField(let fieldId)?):
            database = ""
            additionalFields[fieldId] = path
        default:
            database = entry["DatabaseName"] as? String ?? ""
        }

        let databaseMode = TablePlusPasswordMode.resolve(entry["DatabasePasswordMode"])
        if databaseMode.promptsForPassword, !Self.hidesBuiltInPassword(dbType, fields: additionalFields) {
            additionalFields["promptForPassword"] = "true"
        }

        let groupName: String?
        if let groupId = entry["GroupID"] as? String, !groupId.isEmpty {
            groupName = groupMap[groupId]
        } else {
            groupName = nil
        }

        let sshConfig = parseSSHConfig(entry)
        let sslConfig = parseSSLConfig(entry, driver: driver)
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
            additionalFields: additionalFields.isEmpty ? nil : additionalFields,
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
        let keyPath = useKey ? importedKeyPath(entry["ServerPrivateKeyName"] as? String ?? "") : ""

        return ExportableSSHConfig(
            enabled: true,
            host: host,
            port: port,
            username: username,
            authMethod: useKey ? "Private Key" : "Password",
            privateKeyPath: keyPath,
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private func importedKeyPath(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        let resolved = ForeignAppPathHelper.resolveKeyPath(trimmed)
        guard !resolved.isEmpty else { return "" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return resolved }
        return keyFileExists(PathPortability.expandHome(resolved)) ? resolved : ""
    }

    private func parseSSLConfig(_ entry: [String: Any], driver: String) -> ExportableSSLConfig? {
        guard entry.keys.contains("tLSMode") else { return nil }
        let tlsMode = entry["tLSMode"] as? Int ?? 0
        let form = TablePlusTLSVocabulary.form(forDriver: driver)
        guard tlsMode >= 0, tlsMode < form.modes.count else { return nil }

        let paths = entry["TlsKeyPaths"] as? [String] ?? []
        func certPath(_ slot: Int?) -> String? {
            guard let slot, slot < paths.count, !paths[slot].isEmpty else { return nil }
            return paths[slot]
        }
        return ExportableSSLConfig(
            mode: form.modes[tlsMode].rawValue,
            caCertificatePath: certPath(form.slots.certificateAuthority),
            clientCertificatePath: certPath(form.slots.clientCertificate),
            clientKeyPath: certPath(form.slots.clientKey)
        )
    }

    private func readCredentials(
        for connectionId: String,
        databaseMode: TablePlusPasswordMode,
        serverMode: TablePlusPasswordMode,
        abortFlag: inout Bool
    ) -> ExportableCredentials {
        func read(_ account: String) -> String? {
            guard !abortFlag else { return nil }
            switch readKeychain(Self.keychainService, account) {
            case .found(let value):
                return value
            case .notFound:
                return nil
            case .cancelled:
                abortFlag = true
                return nil
            }
        }

        let dbPassword = databaseMode.storesPasswordInKeychain ? read("\(connectionId)_database") : nil
        let sshPassword = serverMode.storesPasswordInKeychain ? read("\(connectionId)_server") : nil
        let keyPassphrase = read("\(connectionId)_server_key")
        return ExportableCredentials(
            password: dbPassword,
            sshPassword: sshPassword,
            keyPassphrase: keyPassphrase,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    private static func hidesBuiltInPassword(_ typeId: String, fields: [String: String]) -> Bool {
        guard let snapshot = PluginMetadataRegistry.shared.snapshot(for: DatabaseType(rawValue: typeId)) else {
            return false
        }
        if snapshot.connection.hidesBuiltInPassword {
            return true
        }
        return snapshot.connection.additionalConnectionFields.hidesPassword(forValues: fields)
    }

    private static func databaseType(forDriver driver: String) -> String {
        switch driver {
        case "MicrosoftSQLServer": return DatabaseType.mssql.rawValue
        case "Mongo": return DatabaseType.mongodb.rawValue
        case "Cockroach": return DatabaseType.cockroachdb.rawValue
        case "CloudflareD1": return DatabaseType.cloudflareD1.rawValue
        case "LibSQL": return DatabaseType.libsql.rawValue
        case "ElasticSearch": return DatabaseType.elasticsearch.rawValue
        default: return ForeignAppDatabaseType.resolve(driver)
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
