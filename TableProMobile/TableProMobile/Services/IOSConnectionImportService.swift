import Foundation
import os
import TableProDatabase
import TableProImport
import TableProModels

@MainActor
enum IOSConnectionImportService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSConnectionImport")

    static func analyze(_ envelope: ConnectionExportEnvelope, appState: AppState) -> ConnectionImportPreview {
        let candidates = appState.connections.map { connection in
            ConnectionDuplicateCandidate(
                id: connection.id,
                name: connection.name.isEmpty ? connection.host : connection.name,
                host: connection.host,
                port: connection.port,
                database: connection.database,
                username: connection.username,
                redisDatabase: nil
            )
        }
        return ConnectionImportAnalyzer.analyze(
            envelope,
            existingConnections: candidates,
            registeredTypeIds: Set(DatabaseType.allKnownTypes.map(\.rawValue)),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    struct ImportResult {
        let importedCount: Int
        let connectionIdMap: [Int: UUID]
        let newConnectionIdMap: [Int: UUID]
    }

    @discardableResult
    static func performImport(
        _ preview: ConnectionImportPreview,
        resolutions: [UUID: ImportResolution],
        appState: AppState
    ) -> ImportResult {
        createMissingGroupsAndTags(from: preview.envelope, appState: appState)

        let tagIdsByName = lookup(appState.tags.map { ($0.name, $0.id) })
        let groupIdsByName = lookup(appState.groups.map { ($0.name, $0.id) })

        var takenNames = Set(appState.connections.map { normalizedKey($0.name) })
        var sortOrder = (appState.connections.map(\.sortOrder).max() ?? -1) + 1

        let itemIndex: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: preview.items.enumerated().map { ($1.id, $0) }
        )

        var connectionIdMap: [Int: UUID] = [:]
        var newConnectionIdMap: [Int: UUID] = [:]
        var importedCount = 0

        for item in preview.items {
            guard let index = itemIndex[item.id] else { continue }
            switch resolutions[item.id] ?? .skip {
            case .skip:
                continue

            case .importNew, .importAsCopy:
                let resolution = resolutions[item.id]
                let name = resolution == .importAsCopy
                    ? uniqueCopyName(for: item.connection.name, taken: takenNames)
                    : item.connection.name
                takenNames.insert(normalizedKey(name))
                let id = UUID()
                let connection = buildConnection(
                    id: id, from: item.connection, name: name, sortOrder: sortOrder,
                    tagIdsByName: tagIdsByName, groupIdsByName: groupIdsByName
                )
                sortOrder += 1
                appState.addConnection(connection)
                connectionIdMap[index] = id
                newConnectionIdMap[index] = id
                importedCount += 1

            case .replace(let existingId):
                let existingSortOrder = appState.connections.first { $0.id == existingId }?.sortOrder ?? sortOrder
                let connection = buildConnection(
                    id: existingId, from: item.connection, name: item.connection.name, sortOrder: existingSortOrder,
                    tagIdsByName: tagIdsByName, groupIdsByName: groupIdsByName
                )
                appState.updateConnection(connection)
                connectionIdMap[index] = existingId
                importedCount += 1
            }
        }

        logger.info("Imported \(importedCount) connections")
        return ImportResult(
            importedCount: importedCount,
            connectionIdMap: connectionIdMap,
            newConnectionIdMap: newConnectionIdMap
        )
    }

    static func restoreCredentials(
        from envelope: ConnectionExportEnvelope,
        connectionIdMap: [Int: UUID],
        secureStore: any SecureStore
    ) {
        guard let credentials = envelope.credentials else { return }
        for (indexString, creds) in credentials {
            guard let index = Int(indexString), let id = connectionIdMap[index] else { continue }
            let suffix = id.uuidString
            if let password = creds.password {
                try? secureStore.store(password, forKey: "com.TablePro.password.\(suffix)")
            }
            if let sshPassword = creds.sshPassword {
                try? secureStore.store(sshPassword, forKey: "com.TablePro.sshpassword.\(suffix)")
            }
            if let keyPassphrase = creds.keyPassphrase {
                try? secureStore.store(keyPassphrase, forKey: "com.TablePro.keypassphrase.\(suffix)")
            }
        }
    }

    // MARK: - Building

    private static func buildConnection(
        id: UUID,
        from exportable: ExportableConnection,
        name: String,
        sortOrder: Int,
        tagIdsByName: [String: UUID],
        groupIdsByName: [String: UUID]
    ) -> DatabaseConnection {
        let host = exportable.host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : exportable.host

        var sshEnabled = false
        var sshConfiguration: SSHConfiguration?
        if let ssh = exportable.sshConfig, ssh.enabled {
            sshEnabled = true
            sshConfiguration = SSHConfiguration(
                host: ssh.host,
                port: ssh.port ?? 22,
                username: ssh.username,
                authMethod: sshAuthMethod(from: ssh.authMethod),
                privateKeyPath: PathPortability.expandHome(ssh.privateKeyPath).isEmpty
                    ? nil : PathPortability.expandHome(ssh.privateKeyPath),
                jumpHosts: (ssh.jumpHosts ?? []).map {
                    SSHJumpHost(host: $0.host, port: $0.port ?? 22, username: $0.username)
                }
            )
        }

        var sslEnabled = false
        var sslConfiguration: SSLConfiguration?
        if let ssl = exportable.sslConfig {
            let mode = sslMode(from: ssl.mode)
            if mode != .disable {
                sslEnabled = true
                sslConfiguration = SSLConfiguration(
                    mode: mode,
                    caCertificatePath: expandedPath(ssl.caCertificatePath),
                    clientCertificatePath: expandedPath(ssl.clientCertificatePath),
                    clientKeyPath: expandedPath(ssl.clientKeyPath)
                )
            }
        }

        let safeMode = exportable.safeModeLevel.flatMap { SafeModeLevel(rawValue: $0) } ?? .off

        return DatabaseConnection(
            id: id,
            name: name,
            type: DatabaseType(rawValue: exportable.type),
            host: host,
            port: exportable.port,
            username: exportable.username,
            database: exportable.database,
            colorTag: exportable.color,
            safeModeLevel: safeMode,
            additionalFields: exportable.additionalFields ?? [:],
            sshEnabled: sshEnabled,
            sshConfiguration: sshConfiguration,
            sslEnabled: sslEnabled,
            sslConfiguration: sslConfiguration,
            groupId: exportable.groupName.flatMap { groupIdsByName[normalizedKey($0)] },
            tagId: exportable.tagName.flatMap { tagIdsByName[normalizedKey($0)] },
            sortOrder: sortOrder
        )
    }

    private static func createMissingGroupsAndTags(from envelope: ConnectionExportEnvelope, appState: AppState) {
        for exportGroup in envelope.groups ?? [] {
            let exists = appState.groups.contains { normalizedKey($0.name) == normalizedKey(exportGroup.name) }
            guard !exists, !exportGroup.name.isEmpty else { continue }
            let color = exportGroup.color.flatMap { ConnectionColor(rawValue: $0) } ?? .none
            appState.addGroup(ConnectionGroup(name: exportGroup.name, color: color))
        }
        for exportTag in envelope.tags ?? [] {
            let exists = appState.tags.contains { normalizedKey($0.name) == normalizedKey(exportTag.name) }
            guard !exists, !exportTag.name.isEmpty else { continue }
            if let preset = ConnectionTag.presets.first(where: { normalizedKey($0.name) == normalizedKey(exportTag.name) }) {
                appState.addTag(preset)
            } else {
                let color = exportTag.color.flatMap { ConnectionColor(rawValue: $0) } ?? .gray
                appState.addTag(ConnectionTag(name: exportTag.name, color: color))
            }
        }
    }

    // MARK: - Helpers

    private static func sshAuthMethod(from raw: String) -> SSHConfiguration.SSHAuthMethod {
        switch normalizedKey(raw) {
        case "privatekey", "publickey", "private key": return .privateKey
        case "sshagent", "agent", "ssh agent": return .sshAgent
        case "keyboardinteractive", "keyboard interactive": return .keyboardInteractive
        default: return .password
        }
    }

    private static func sslMode(from raw: String) -> SSLConfiguration.SSLMode {
        let key = normalizedKey(raw)
        if key.contains("disab") { return .disable }
        if key.contains("verifyfull") || key.contains("identity") { return .verifyFull }
        if key.contains("verifyca") || key == "verify ca" { return .verifyCa }
        if key.contains("require") || key.contains("prefer") { return .require }
        return .disable
    }

    private static func expandedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return PathPortability.expandHome(path)
    }

    private static func uniqueCopyName(for baseName: String, taken: Set<String>) -> String {
        let first = "\(baseName) (Imported)"
        if !taken.contains(normalizedKey(first)) { return first }
        var suffix = 2
        while true {
            let candidate = "\(baseName) (Imported \(suffix))"
            if !taken.contains(normalizedKey(candidate)) { return candidate }
            suffix += 1
        }
    }

    private static func lookup(_ pairs: [(String, UUID)]) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for (name, id) in pairs where !name.isEmpty {
            let key = normalizedKey(name)
            if result[key] == nil { result[key] = id }
        }
        return result
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
