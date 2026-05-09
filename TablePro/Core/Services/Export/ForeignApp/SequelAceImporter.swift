//
//  SequelAceImporter.swift
//  TablePro
//

import Foundation
import os

struct SequelAceImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SequelAceImporter")

    let id = "sequelace"
    let displayName = "Sequel Ace"
    let symbolName = "cylinder.split.1x2"
    let appBundleIdentifier = "com.sequel-ace.sequel-ace"

    var favoritesFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Containers/com.sequel-ace.sequel-ace/Data/Library/Application Support/"
                + "Sequel Ace/Data/Favorites.plist"
        )

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: favoritesFileURL.path)
    }

    func connectionCount() -> Int {
        guard let root = loadRootDict() else { return 0 }
        guard let favoritesRoot = root["Favorites Root"] as? [String: Any],
              let children = favoritesRoot["Children"] as? [[String: Any]] else { return 0 }
        return countConnections(in: children)
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        guard FileManager.default.fileExists(atPath: favoritesFileURL.path) else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        guard let root = loadRootDict() else {
            throw ForeignAppImportError.parseError("Could not read Favorites.plist")
        }

        guard let favoritesRoot = root["Favorites Root"] as? [String: Any],
              let children = favoritesRoot["Children"] as? [[String: Any]] else {
            throw ForeignAppImportError.unsupportedFormat("Missing Favorites Root or Children key")
        }

        var exportableConnections: [ExportableConnection] = []
        var groupNames: Set<String> = []
        var credentials: [String: ExportableCredentials] = [:]
        var credentialsAborted = false

        try parseChildren(
            children,
            groupName: nil,
            connections: &exportableConnections,
            groupNames: &groupNames,
            credentials: &credentials,
            includePasswords: includePasswords,
            credentialsAborted: &credentialsAborted
        )

        guard !exportableConnections.isEmpty else {
            throw ForeignAppImportError.noConnectionsFound
        }

        let groups: [ExportableGroup]? = groupNames.isEmpty ? nil : groupNames.map {
            ExportableGroup(name: $0, color: nil)
        }

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "Sequel Ace Import",
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

    private func loadRootDict() -> [String: Any]? {
        guard let data = try? Data(contentsOf: favoritesFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict
    }

    private func countConnections(in children: [[String: Any]]) -> Int {
        var count = 0
        for child in children {
            if child["host"] != nil || (child["id"] is NSNumber && child["Children"] == nil) {
                count += 1
            } else if let subChildren = child["Children"] as? [[String: Any]] {
                count += countConnections(in: subChildren)
            }
        }
        return count
    }

    private func parseChildren(
        _ children: [[String: Any]],
        groupName: String?,
        connections: inout [ExportableConnection],
        groupNames: inout Set<String>,
        credentials: inout [String: ExportableCredentials],
        includePasswords: Bool,
        credentialsAborted: inout Bool
    ) throws {
        for child in children {
            try Task.checkCancellation()
            if let subChildren = child["Children"] as? [[String: Any]] {
                let name = child["Name"] as? String ?? "Untitled Group"
                groupNames.insert(name)
                try parseChildren(
                    subChildren,
                    groupName: name,
                    connections: &connections,
                    groupNames: &groupNames,
                    credentials: &credentials,
                    includePasswords: includePasswords,
                    credentialsAborted: &credentialsAborted
                )
            } else {
                do {
                    let conn = try parseConnection(child, groupName: groupName)
                    let index = connections.count
                    connections.append(conn)

                    if let gn = groupName {
                        groupNames.insert(gn)
                    }

                    if includePasswords, !credentialsAborted {
                        let creds = readCredentials(from: child, abortFlag: &credentialsAborted)
                        if creds.password != nil || creds.sshPassword != nil {
                            credentials[String(index)] = creds
                        }
                    }
                } catch {
                    Self.logger.warning("Skipping Sequel Ace connection: \(error.localizedDescription)")
                }
            }
        }
    }

    private func parseConnection(
        _ entry: [String: Any],
        groupName: String?
    ) throws -> ExportableConnection {
        let name = entry["name"] as? String ?? "Untitled"
        let host = entry["host"] as? String ?? "localhost"
        let port: Int
        if let intPort = entry["port"] as? Int {
            port = intPort
        } else if let strPort = entry["port"] as? String, let parsed = Int(strPort) {
            port = parsed
        } else {
            port = 3_306
        }
        let username = entry["user"] as? String ?? ""
        let database = entry["database"] as? String ?? ""

        let connectionType = entry["type"] as? Int ?? 0
        let sshConfig = parseSSHConfig(entry, connectionType: connectionType)
        let sslConfig = parseSSLConfig(entry)

        let colorIndex = entry["colorIndex"] as? Int ?? -1
        let color = mapColorIndex(colorIndex)

        return ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: "MySQL",
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

    private func parseSSHConfig(_ entry: [String: Any], connectionType: Int) -> ExportableSSHConfig? {
        guard connectionType == 2 else { return nil }
        let host = entry["sshHost"] as? String ?? ""
        let user = entry["sshUser"] as? String ?? ""
        let port: Int?
        if let intPort = entry["sshPort"] as? Int {
            port = intPort
        } else if let strPort = entry["sshPort"] as? String, let parsed = Int(strPort) {
            port = parsed
        } else {
            port = nil
        }
        let keyEnabled = (entry["sshKeyLocationEnabled"] as? Int ?? 0) != 0
        let rawKeyPath = entry["sshKeyLocation"] as? String ?? ""
        let keyPath = ForeignAppPathHelper.resolveKeyPath(rawKeyPath)

        return ExportableSSHConfig(
            enabled: true,
            host: host,
            port: port,
            username: user,
            authMethod: keyEnabled ? "Private Key" : "Password",
            privateKeyPath: keyEnabled ? keyPath : "",
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private func parseSSLConfig(_ entry: [String: Any]) -> ExportableSSLConfig? {
        let useSSL: Bool
        if let intVal = entry["useSSL"] as? Int {
            useSSL = intVal != 0
        } else if let boolVal = entry["useSSL"] as? Bool {
            useSSL = boolVal
        } else {
            useSSL = false
        }
        guard useSSL else { return nil }

        return ExportableSSLConfig(
            mode: "Required",
            caCertificatePath: entry["sslCACertFileLocation"] as? String,
            clientCertificatePath: entry["sslCertificateFileLocation"] as? String,
            clientKeyPath: entry["sslKeyFileLocation"] as? String
        )
    }

    private func readCredentials(from entry: [String: Any], abortFlag: inout Bool) -> ExportableCredentials {
        let name = entry["name"] as? String ?? ""
        let connId = entry["id"] ?? 0
        let user = entry["user"] as? String ?? ""
        let host = entry["host"] as? String ?? ""
        let database = entry["database"] as? String ?? ""

        func read(service: String, account: String) -> String? {
            guard !abortFlag else { return nil }
            switch ForeignKeychainReader.readPassword(service: service, account: account) {
            case .found(let value):
                return value
            case .notFound:
                return nil
            case .cancelled:
                abortFlag = true
                return nil
            }
        }

        let dbPassword = read(
            service: "Sequel Ace : \(name) (\(connId))",
            account: "\(user)@\(host)/\(database)"
        )

        var sshPassword: String?
        let connectionType = entry["type"] as? Int ?? 0
        if connectionType == 2 {
            let sshUser = entry["sshUser"] as? String ?? ""
            let sshHost = entry["sshHost"] as? String ?? ""
            sshPassword = read(
                service: "Sequel Ace SSHTunnel : \(name) (\(connId))",
                account: "\(sshUser)@\(sshHost)"
            )
        }

        return ExportableCredentials(
            password: dbPassword,
            sshPassword: sshPassword,
            keyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    private func mapColorIndex(_ index: Int) -> String? {
        switch index {
        case 0: return "Red"
        case 1: return "Orange"
        case 2: return "Yellow"
        case 3: return "Green"
        case 4: return "Blue"
        case 5: return "Purple"
        case 6: return "Pink"
        case 7: return "Gray"
        default: return nil
        }
    }
}
