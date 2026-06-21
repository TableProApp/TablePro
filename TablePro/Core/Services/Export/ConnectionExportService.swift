//
//  ConnectionExportService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProImport
import TableProPluginKit
import UniformTypeIdentifiers

// MARK: - Prepared Import

enum PreparedImportOperation {
    case add(DatabaseConnection)
    case replace(DatabaseConnection)
}

struct PreparedConnectionImport {
    let operations: [PreparedImportOperation]
    let connectionIdMap: [Int: UUID]
    let newConnectionIdMap: [Int: UUID]

    var importedCount: Int { operations.count }
}

// MARK: - Connection Export Service

@MainActor
enum ConnectionExportService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionExportService")
    private static let currentFormatVersion = 1

    // MARK: - Export

    static func buildEnvelope(for connections: [DatabaseConnection]) -> ConnectionExportEnvelope {
        var groupNames: Set<String> = []
        var tagNames: Set<String> = []
        var exportableConnections: [ExportableConnection] = []

        for connection in connections {
            // Resolve SSH config: prefer SSH profile if linked, otherwise use inline config
            let sshConfig: SSHConfiguration
            if let profileId = connection.sshProfileId,
               let profile = SSHProfileStorage.shared.profile(for: profileId) {
                sshConfig = profile.toSSHConfiguration()
            } else {
                sshConfig = connection.sshConfig
            }

            let tagName: String?
            if let tagId = connection.tagId {
                tagName = TagStorage.shared.tag(for: tagId)?.name
            } else {
                tagName = nil
            }

            let groupName: String?
            if let groupId = connection.groupId {
                groupName = GroupStorage.shared.group(for: groupId)?.name
            } else {
                groupName = nil
            }

            // Build exportable SSH config (nil if not enabled)
            let exportableSSH: ExportableSSHConfig?
            if sshConfig.enabled {
                let jumpHosts: [ExportableJumpHost]? = sshConfig.jumpHosts.isEmpty ? nil : sshConfig.jumpHosts.map {
                    ExportableJumpHost(
                        host: $0.host,
                        port: $0.port,
                        username: $0.username,
                        authMethod: $0.authMethod.rawValue,
                        privateKeyPath: PathPortability.contractHome($0.privateKeyPath)
                    )
                }
                exportableSSH = ExportableSSHConfig(
                    enabled: true,
                    host: sshConfig.host,
                    port: sshConfig.port,
                    username: sshConfig.username,
                    authMethod: sshConfig.authMethod.rawValue,
                    privateKeyPath: PathPortability.contractHome(sshConfig.privateKeyPath),
                    agentSocketPath: PathPortability.contractHome(sshConfig.agentSocketPath),
                    jumpHosts: jumpHosts,
                    totpMode: sshConfig.totpMode == .none ? nil : sshConfig.totpMode.rawValue,
                    totpAlgorithm: sshConfig.totpAlgorithm == .sha1 ? nil : sshConfig.totpAlgorithm.rawValue,
                    totpDigits: sshConfig.totpDigits == 6 ? nil : sshConfig.totpDigits,
                    totpPeriod: sshConfig.totpPeriod == 30 ? nil : sshConfig.totpPeriod
                )
            } else {
                exportableSSH = nil
            }

            // Build exportable SSL config (nil if disabled)
            let exportableSSL: ExportableSSLConfig?
            if connection.sslConfig.mode != .disabled {
                exportableSSL = ExportableSSLConfig(
                    mode: connection.sslConfig.mode.rawValue,
                    caCertificatePath: PathPortability.contractHome(connection.sslConfig.caCertificatePath),
                    clientCertificatePath: PathPortability.contractHome(connection.sslConfig.clientCertificatePath),
                    clientKeyPath: PathPortability.contractHome(connection.sslConfig.clientKeyPath)
                )
            } else {
                exportableSSL = nil
            }

            let color: String? = connection.color == .none ? nil : connection.color.rawValue

            let safeModeLevel: String? = connection.safeModeLevel == .silent ? nil : connection.safeModeLevel.rawValue

            let aiPolicy: String? = connection.aiPolicy?.rawValue

            // Filter secure fields from additionalFields
            // If plugin metadata is unavailable, omit all fields to avoid leaking secrets
            let additionalFields: [String: String]?
            if let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: connection.type.pluginTypeId) {
                var filteredFields = connection.additionalFields
                let secureFieldIds = snapshot.connection.additionalConnectionFields
                    .filter(\.isSecure)
                    .map(\.id)
                for fieldId in secureFieldIds {
                    filteredFields.removeValue(forKey: fieldId)
                }
                additionalFields = filteredFields.isEmpty ? nil : filteredFields
            } else {
                additionalFields = nil
            }

            let exportable = ExportableConnection(
                name: connection.name,
                host: connection.host,
                port: connection.port,
                database: connection.database,
                username: connection.username,
                type: connection.type.rawValue,
                sshConfig: exportableSSH,
                sslConfig: exportableSSL,
                color: color,
                tagName: tagName,
                groupName: groupName,
                sshProfileId: connection.sshProfileId?.uuidString,
                safeModeLevel: safeModeLevel,
                aiPolicy: aiPolicy,
                additionalFields: additionalFields,
                redisDatabase: connection.redisDatabase,
                startupCommands: connection.startupCommands,
                localOnly: connection.localOnly ? true : nil
            )

            exportableConnections.append(exportable)

            if let name = tagName { tagNames.insert(name) }
            if let name = groupName { groupNames.insert(name) }
        }

        // Build group and tag arrays with their colors
        let allGroups = GroupStorage.shared.loadGroups()
        let exportableGroups: [ExportableGroup]? = groupNames.isEmpty ? nil : groupNames.map { name in
            let existing = allGroups.first { $0.name == name }
            return ExportableGroup(name: name, color: existing?.color == .none ? nil : existing?.color.rawValue)
        }

        let allTags = TagStorage.shared.loadTags()
        let exportableTags: [ExportableTag]? = tagNames.isEmpty ? nil : tagNames.map { name in
            let existing = allTags.first { $0.name == name }
            return ExportableTag(name: name, color: existing?.color == .none ? nil : existing?.color.rawValue)
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        return ConnectionExportEnvelope(
            formatVersion: currentFormatVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            connections: exportableConnections,
            groups: exportableGroups,
            tags: exportableTags,
            credentials: nil
        )
    }

    static func encode(_ envelope: ConnectionExportEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            return try encoder.encode(envelope)
        } catch {
            logger.error("Encoding failed: \(error)")
            throw ConnectionExportError.encodingFailed
        }
    }

    static func exportData(_ connections: [DatabaseConnection]) throws -> Data {
        try encode(buildEnvelope(for: connections))
    }

    static func exportConnections(_ connections: [DatabaseConnection], to url: URL) throws {
        let data = try exportData(connections)

        do {
            try data.write(to: url, options: .atomic)
            logger.info("Exported \(connections.count) connections to \(url.path)")
        } catch {
            throw ConnectionExportError.fileWriteFailed(url.path)
        }
    }

    // MARK: - Encrypted Export

    static func buildEnvelopeWithCredentials(for connections: [DatabaseConnection]) -> ConnectionExportEnvelope {
        let baseEnvelope = buildEnvelope(for: connections)

        var credentialsMap: [String: ExportableCredentials] = [:]
        for (index, connection) in connections.enumerated() {
            let password = ConnectionStorage.shared.loadPassword(for: connection.id)
            let sshPassword = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
            let keyPassphrase = ConnectionStorage.shared.loadKeyPassphrase(for: connection.id)
            let sslClientKeyPassphrase = ConnectionStorage.shared.loadSSLClientKeyPassphrase(for: connection.id)
            let totpSecret = ConnectionStorage.shared.loadTOTPSecret(for: connection.id)

            // Collect plugin-specific secure fields
            var pluginSecureFields: [String: String]?
            if let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: connection.type.pluginTypeId) {
                let secureFieldIds = snapshot.connection.additionalConnectionFields
                    .filter(\.isSecure)
                    .map(\.id)
                if !secureFieldIds.isEmpty {
                    var fields: [String: String] = [:]
                    for fieldId in secureFieldIds {
                        if let value = ConnectionStorage.shared.loadPluginSecureField(
                            fieldId: fieldId,
                            for: connection.id
                        ) {
                            fields[fieldId] = value
                        }
                    }
                    if !fields.isEmpty {
                        pluginSecureFields = fields
                    }
                }
            }

            let hasAnyCredential = password != nil || sshPassword != nil
                || keyPassphrase != nil || sslClientKeyPassphrase != nil
                || totpSecret != nil || pluginSecureFields != nil

            if hasAnyCredential {
                credentialsMap[String(index)] = ExportableCredentials(
                    password: password,
                    sshPassword: sshPassword,
                    keyPassphrase: keyPassphrase,
                    sslClientKeyPassphrase: sslClientKeyPassphrase,
                    totpSecret: totpSecret,
                    pluginSecureFields: pluginSecureFields
                )
            }
        }

        return ConnectionExportEnvelope(
            formatVersion: baseEnvelope.formatVersion,
            exportedAt: baseEnvelope.exportedAt,
            appVersion: baseEnvelope.appVersion,
            connections: baseEnvelope.connections,
            groups: baseEnvelope.groups,
            tags: baseEnvelope.tags,
            credentials: credentialsMap.isEmpty ? nil : credentialsMap
        )
    }

    static func exportEncryptedData(_ connections: [DatabaseConnection], passphrase: String) throws -> Data {
        let jsonData = try encode(buildEnvelopeWithCredentials(for: connections))
        return try ConnectionExportCrypto.encrypt(data: jsonData, passphrase: passphrase)
    }

    static func exportConnectionsEncrypted(
        _ connections: [DatabaseConnection],
        to url: URL,
        passphrase: String
    ) throws {
        let encryptedData = try exportEncryptedData(connections, passphrase: passphrase)

        do {
            try encryptedData.write(to: url, options: .atomic)
            logger.info("Exported \(connections.count) encrypted connections to \(url.path)")
        } catch {
            throw ConnectionExportError.fileWriteFailed(url.path)
        }
    }

    // MARK: - Import

    static func decodeFile(at url: URL) throws -> ConnectionExportEnvelope {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConnectionExportError.fileReadFailed(url.path)
        }

        if ConnectionExportCrypto.isEncrypted(data) {
            throw ConnectionExportError.requiresPassphrase
        }

        return try ConnectionImportDecoder.decodeData(data)
    }

    static func restoreCredentials(from envelope: ConnectionExportEnvelope, connectionIdMap: [Int: UUID]) {
        guard let credentials = envelope.credentials else { return }

        var restoredCount = 0
        for (indexString, creds) in credentials {
            guard let index = Int(indexString),
                  let connectionId = connectionIdMap[index] else { continue }

            if let password = creds.password {
                ConnectionStorage.shared.savePassword(password, for: connectionId)
            }
            if let sshPassword = creds.sshPassword {
                ConnectionStorage.shared.saveSSHPassword(sshPassword, for: connectionId)
            }
            if let keyPassphrase = creds.keyPassphrase {
                ConnectionStorage.shared.saveKeyPassphrase(keyPassphrase, for: connectionId)
            }
            if let sslClientKeyPassphrase = creds.sslClientKeyPassphrase {
                ConnectionStorage.shared.saveSSLClientKeyPassphrase(sslClientKeyPassphrase, for: connectionId)
            }
            if let totpSecret = creds.totpSecret {
                ConnectionStorage.shared.saveTOTPSecret(totpSecret, for: connectionId)
            }
            if let secureFields = creds.pluginSecureFields {
                for (fieldId, value) in secureFields {
                    ConnectionStorage.shared.savePluginSecureField(value, fieldId: fieldId, for: connectionId)
                }
            }
            restoredCount += 1
        }

        logger.info("Restored credentials for \(restoredCount) of \(credentials.count) connections")
    }

    static func analyzeImport(_ envelope: ConnectionExportEnvelope) -> ConnectionImportPreview {
        analyzeImport(
            envelope,
            existingConnections: ConnectionStorage.shared.loadConnections(),
            registeredTypeIds: Set(PluginMetadataRegistry.shared.allRegisteredTypeIds()),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    static func analyzeImport(
        _ envelope: ConnectionExportEnvelope,
        existingConnections: [DatabaseConnection],
        registeredTypeIds: Set<String>,
        fileExists: (String) -> Bool
    ) -> ConnectionImportPreview {
        ConnectionImportAnalyzer.analyze(
            envelope,
            existingConnections: existingConnections.map(duplicateCandidate(for:)),
            registeredTypeIds: registeredTypeIds,
            fileExists: fileExists
        )
    }

    struct ImportResult {
        let importedCount: Int
        let connectionIdMap: [Int: UUID] // envelope index -> connection UUID (added and replaced)
        let newConnectionIdMap: [Int: UUID] // envelope index -> UUID, added connections only
    }

    @discardableResult
    static func performImport(
        _ preview: ConnectionImportPreview,
        resolutions: [UUID: ImportResolution]
    ) -> ImportResult {
        if let envelopeGroups = preview.envelope.groups {
            let existingGroups = GroupStorage.shared.loadGroups()
            for exportGroup in envelopeGroups {
                let alreadyExists = existingGroups.contains {
                    $0.name.lowercased() == exportGroup.name.lowercased()
                }
                if !alreadyExists {
                    let color = exportGroup.color.flatMap { ConnectionColor(rawValue: $0) } ?? .none
                    let group = ConnectionGroup(name: exportGroup.name, color: color)
                    GroupStorage.shared.addGroup(group)
                }
            }
        }

        if let envelopeTags = preview.envelope.tags {
            let existingTags = TagStorage.shared.loadTags()
            for exportTag in envelopeTags {
                let alreadyExists = existingTags.contains {
                    $0.name.lowercased() == exportTag.name.lowercased()
                }
                if !alreadyExists {
                    // Match preset tags by name
                    let preset = ConnectionTag.presets.first {
                        $0.name.lowercased() == exportTag.name.lowercased()
                    }
                    if let preset {
                        TagStorage.shared.addTag(preset)
                    } else {
                        let color = exportTag.color.flatMap { ConnectionColor(rawValue: $0) } ?? .gray
                        let tag = ConnectionTag(name: exportTag.name, color: color)
                        TagStorage.shared.addTag(tag)
                    }
                }
            }
        }

        let prepared = prepareImport(
            preview,
            resolutions: resolutions,
            existingNames: ConnectionStorage.shared.loadConnections().map(\.name),
            tagIdsByName: tagIdsByName(),
            groupIdsByName: groupIdsByName()
        )

        return performPreparedImport(prepared)
    }

    static func prepareImport(
        _ preview: ConnectionImportPreview,
        resolutions: [UUID: ImportResolution],
        existingNames: [String] = [],
        tagIdsByName: [String: UUID],
        groupIdsByName: [String: UUID]
    ) -> PreparedConnectionImport {
        var operations: [PreparedImportOperation] = []
        var connectionIdMap: [Int: UUID] = [:]
        var newConnectionIdMap: [Int: UUID] = [:]
        var takenNames = Set(existingNames.map { normalizedLookupKey($0) })

        let itemIndexMap: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: preview.items.enumerated().map { ($1.id, $0) }
        )

        for item in preview.items {
            let resolution = resolutions[item.id] ?? .skip
            guard let envelopeIndex = itemIndexMap[item.id] else { continue }

            switch resolution {
            case .skip:
                continue

            case .importNew, .importAsCopy:
                let connectionId = UUID()
                let name: String
                if resolution == .importAsCopy {
                    name = uniqueCopyName(for: item.connection.name, taken: takenNames)
                } else {
                    name = item.connection.name
                }
                takenNames.insert(normalizedLookupKey(name))
                let connection = buildDatabaseConnection(
                    id: connectionId,
                    from: item.connection,
                    name: name,
                    tagIdsByName: tagIdsByName,
                    groupIdsByName: groupIdsByName
                )
                operations.append(.add(connection))
                connectionIdMap[envelopeIndex] = connectionId
                newConnectionIdMap[envelopeIndex] = connectionId

            case .replace(let existingId):
                let connection = buildDatabaseConnection(
                    id: existingId,
                    from: item.connection,
                    name: item.connection.name,
                    tagIdsByName: tagIdsByName,
                    groupIdsByName: groupIdsByName
                )
                operations.append(.replace(connection))
                connectionIdMap[envelopeIndex] = existingId
            }
        }

        return PreparedConnectionImport(
            operations: operations,
            connectionIdMap: connectionIdMap,
            newConnectionIdMap: newConnectionIdMap
        )
    }

    @discardableResult
    static func performPreparedImport(
        _ prepared: PreparedConnectionImport,
        connectionStorage: ConnectionStorage = .shared,
        notifyConnectionsChanged: () -> Void = { AppEvents.shared.connectionUpdated.send(nil) }
    ) -> ImportResult {
        for operation in prepared.operations {
            switch operation {
            case .add(let connection):
                connectionStorage.addConnection(connection, password: nil)
            case .replace(let connection):
                connectionStorage.updateConnection(connection, password: nil)
            }
        }

        if prepared.importedCount > 0 {
            notifyConnectionsChanged()
            logger.info("Imported \(prepared.importedCount) connections")
        }

        return ImportResult(
            importedCount: prepared.importedCount,
            connectionIdMap: prepared.connectionIdMap,
            newConnectionIdMap: prepared.newConnectionIdMap
        )
    }

    // MARK: - Deeplink Builder

    static func buildImportDeeplink(for connection: DatabaseConnection) -> String? {
        let envelope = buildEnvelope(for: [connection])
        guard let exportable = envelope.connections.first else { return nil }

        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "name", value: exportable.name),
            URLQueryItem(name: "host", value: exportable.host),
            URLQueryItem(name: "port", value: String(exportable.port)),
            URLQueryItem(name: "type", value: exportable.type)
        ]

        if !exportable.username.isEmpty {
            queryItems.append(URLQueryItem(name: "username", value: exportable.username))
        }
        if !exportable.database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: exportable.database))
        }

        if let ssh = exportable.sshConfig {
            queryItems.append(URLQueryItem(name: "ssh", value: "1"))
            queryItems.append(URLQueryItem(name: "sshHost", value: ssh.host))
            if let port = ssh.port, port != 22 {
                queryItems.append(URLQueryItem(name: "sshPort", value: String(port)))
            }
            if !ssh.username.isEmpty {
                queryItems.append(URLQueryItem(name: "sshUsername", value: ssh.username))
            }
            queryItems.append(URLQueryItem(name: "sshAuthMethod", value: ssh.authMethod))
            if !ssh.privateKeyPath.isEmpty {
                queryItems.append(URLQueryItem(name: "sshPrivateKeyPath", value: ssh.privateKeyPath))
            }
            if !ssh.agentSocketPath.isEmpty {
                queryItems.append(URLQueryItem(name: "sshAgentSocketPath", value: ssh.agentSocketPath))
            }
            if let jumpHosts = ssh.jumpHosts, !jumpHosts.isEmpty,
               let jumpData = try? JSONEncoder().encode(jumpHosts),
               let jumpStr = String(data: jumpData, encoding: .utf8) {
                queryItems.append(URLQueryItem(name: "sshJumpHosts", value: jumpStr))
            }
            if let totpMode = ssh.totpMode {
                queryItems.append(URLQueryItem(name: "sshTotpMode", value: totpMode))
            }
            if let totpAlgorithm = ssh.totpAlgorithm {
                queryItems.append(URLQueryItem(name: "sshTotpAlgorithm", value: totpAlgorithm))
            }
            if let totpDigits = ssh.totpDigits {
                queryItems.append(URLQueryItem(name: "sshTotpDigits", value: String(totpDigits)))
            }
            if let totpPeriod = ssh.totpPeriod {
                queryItems.append(URLQueryItem(name: "sshTotpPeriod", value: String(totpPeriod)))
            }
        }

        if let ssl = exportable.sslConfig {
            queryItems.append(URLQueryItem(name: "sslMode", value: ssl.mode))
            if let path = ssl.caCertificatePath, !path.isEmpty {
                queryItems.append(URLQueryItem(name: "sslCaCertPath", value: path))
            }
            if let path = ssl.clientCertificatePath, !path.isEmpty {
                queryItems.append(URLQueryItem(name: "sslClientCertPath", value: path))
            }
            if let path = ssl.clientKeyPath, !path.isEmpty {
                queryItems.append(URLQueryItem(name: "sslClientKeyPath", value: path))
            }
        }

        if let color = exportable.color {
            queryItems.append(URLQueryItem(name: "color", value: color))
        }
        if let tagName = exportable.tagName {
            queryItems.append(URLQueryItem(name: "tagName", value: tagName))
        }
        if let groupName = exportable.groupName {
            queryItems.append(URLQueryItem(name: "groupName", value: groupName))
        }
        if let safeModeLevel = exportable.safeModeLevel {
            queryItems.append(URLQueryItem(name: "safeModeLevel", value: safeModeLevel))
        }
        if let aiPolicy = exportable.aiPolicy {
            queryItems.append(URLQueryItem(name: "aiPolicy", value: aiPolicy))
        }
        if let redisDb = exportable.redisDatabase {
            queryItems.append(URLQueryItem(name: "redisDatabase", value: String(redisDb)))
        }
        if let commands = exportable.startupCommands, !commands.isEmpty {
            queryItems.append(URLQueryItem(name: "startupCommands", value: commands))
        }
        if exportable.localOnly == true {
            queryItems.append(URLQueryItem(name: "localOnly", value: "1"))
        }

        if let fields = exportable.additionalFields {
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                queryItems.append(URLQueryItem(name: "af_\(key)", value: value))
            }
        }

        components.queryItems = queryItems
        guard let url = components.url?.absoluteString, !url.isEmpty else {
            logger.warning("Failed to build import deeplink for '\(connection.name)'")
            return nil
        }
        if (url as NSString).length > 2_000 {
            logger.warning("Import deeplink for '\(connection.name)' is \((url as NSString).length) chars — may be truncated by some apps")
        }
        return url
    }

    static func buildCompactJSON(for connection: DatabaseConnection) -> String {
        let envelope = buildEnvelope(for: [connection])
        guard let exportable = envelope.connections.first else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(exportable),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - Private Helpers

    static func buildDatabaseConnection(
        id: UUID,
        from exportable: ExportableConnection,
        name: String,
        tagIdsByName: [String: UUID],
        groupIdsByName: [String: UUID]
    ) -> DatabaseConnection {
        // Build SSH configuration
        let sshConfig: SSHConfiguration
        if let ssh = exportable.sshConfig {
            var config = SSHConfiguration()
            config.enabled = ssh.enabled
            config.host = ssh.host
            config.port = ssh.port
            config.username = ssh.username
            config.authMethod = SSHAuthMethod(rawValue: ssh.authMethod) ?? .password
            config.privateKeyPath = PathPortability.expandHome(ssh.privateKeyPath)
            config.agentSocketPath = PathPortability.expandHome(ssh.agentSocketPath)
            config.jumpHosts = (ssh.jumpHosts ?? []).map { jump in
                SSHJumpHost(
                    host: jump.host,
                    port: jump.port,
                    username: jump.username,
                    authMethod: SSHJumpAuthMethod(rawValue: jump.authMethod) ?? .sshAgent,
                    privateKeyPath: PathPortability.expandHome(jump.privateKeyPath)
                )
            }
            config.totpMode = ssh.totpMode.flatMap { TOTPMode(rawValue: $0) } ?? .none
            config.totpAlgorithm = ssh.totpAlgorithm.flatMap { TOTPAlgorithm(rawValue: $0) } ?? .sha1
            config.totpDigits = ssh.totpDigits ?? 6
            config.totpPeriod = ssh.totpPeriod ?? 30
            sshConfig = config
        } else {
            sshConfig = SSHConfiguration()
        }

        // Build SSL configuration
        let sslConfig: SSLConfiguration
        if let ssl = exportable.sslConfig {
            sslConfig = SSLConfiguration(
                mode: SSLMode(rawValue: ssl.mode) ?? .disabled,
                caCertificatePath: PathPortability.expandHome(ssl.caCertificatePath ?? ""),
                clientCertificatePath: PathPortability.expandHome(ssl.clientCertificatePath ?? ""),
                clientKeyPath: PathPortability.expandHome(ssl.clientKeyPath ?? "")
            )
        } else {
            sslConfig = SSLConfiguration()
        }

        // Resolve tag and group by name
        let tagId = exportable.tagName.flatMap { name in
            tagIdsByName[normalizedLookupKey(name)]
        }
        let groupId = exportable.groupName.flatMap { name in
            groupIdsByName[normalizedLookupKey(name)]
        }

        let parsedSSHProfileId = exportable.sshProfileId.flatMap { UUID(uuidString: $0) }

        let finalHost = exportable.host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "localhost" : exportable.host

        return DatabaseConnection(
            id: id,
            name: name,
            host: finalHost,
            port: exportable.port,
            database: exportable.database,
            username: exportable.username,
            type: DatabaseType(rawValue: exportable.type),
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: exportable.color.flatMap { ConnectionColor(rawValue: $0) } ?? .none,
            tagId: tagId,
            groupId: groupId,
            sshProfileId: parsedSSHProfileId,
            safeModeLevel: exportable.safeModeLevel.flatMap { SafeModeLevel(rawValue: $0) } ?? .silent,
            aiPolicy: exportable.aiPolicy.flatMap { AIConnectionPolicy(rawValue: $0) },
            redisDatabase: exportable.redisDatabase,
            startupCommands: exportable.startupCommands,
            localOnly: exportable.localOnly ?? false,
            additionalFields: exportable.additionalFields
        )
    }

    private static func uniqueCopyName(for baseName: String, taken: Set<String>) -> String {
        let firstCandidate = "\(baseName) (Imported)"
        if !taken.contains(normalizedLookupKey(firstCandidate)) {
            return firstCandidate
        }
        var suffix = 2
        while true {
            let candidate = "\(baseName) (Imported \(suffix))"
            if !taken.contains(normalizedLookupKey(candidate)) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func duplicateCandidate(for connection: DatabaseConnection) -> ConnectionDuplicateCandidate {
        ConnectionDuplicateCandidate(
            id: connection.id,
            name: connection.name,
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            redisDatabase: connection.redisDatabase
        )
    }

    private static func tagIdsByName() -> [String: UUID] {
        var idsByName: [String: UUID] = [:]
        for tag in TagStorage.shared.loadTags() {
            let key = normalizedLookupKey(tag.name)
            if idsByName[key] == nil {
                idsByName[key] = tag.id
            }
        }
        return idsByName
    }

    private static func groupIdsByName() -> [String: UUID] {
        var idsByName: [String: UUID] = [:]
        for group in GroupStorage.shared.loadGroups() {
            let key = normalizedLookupKey(group.name)
            if idsByName[key] == nil {
                idsByName[key] = group.id
            }
        }
        return idsByName
    }

    private static func normalizedLookupKey(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}
