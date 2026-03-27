//
//  ConnectionExportService.swift
//  TablePro
//

import Foundation
import os
import UniformTypeIdentifiers

// MARK: - Export Error

enum ConnectionExportError: LocalizedError {
    case encodingFailed
    case fileWriteFailed(String)
    case fileReadFailed(String)
    case invalidFormat
    case unsupportedVersion(Int)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return String(localized: "Failed to encode connection data")
        case .fileWriteFailed(let path):
            return String(localized: "Failed to write file: \(path)")
        case .fileReadFailed(let path):
            return String(localized: "Failed to read file: \(path)")
        case .invalidFormat:
            return String(localized: "This file is not a valid TablePro export")
        case .unsupportedVersion(let version):
            return String(localized: "This file requires a newer version of TablePro (format version \(version))")
        case .decodingFailed(let detail):
            return String(localized: "Failed to parse connection file: \(detail)")
        }
    }
}

// MARK: - Import Preview Types

enum ImportItemStatus {
    case ready
    case duplicate(existing: DatabaseConnection)
    case warnings([String])
}

struct ImportItem: Identifiable {
    let id = UUID()
    let connection: ExportableConnection
    let status: ImportItemStatus
}

enum ImportResolution: Hashable {
    case importNew
    case skip
    case replace(existingId: UUID)
    case importAsCopy
}

struct ConnectionImportPreview {
    let envelope: ConnectionExportEnvelope
    let items: [ImportItem]
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

            // Resolve tag name
            let tagName: String?
            if let tagId = connection.tagId {
                tagName = TagStorage.shared.tag(for: tagId)?.name
            } else {
                tagName = nil
            }

            // Resolve group name
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
                    useSSHConfig: sshConfig.useSSHConfig,
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

            // Color
            let color: String? = connection.color == .none ? nil : connection.color.rawValue

            // Safe mode level
            let safeModeLevel: String? = connection.safeModeLevel == .silent ? nil : connection.safeModeLevel.rawValue

            // AI policy
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
                safeModeLevel: safeModeLevel,
                aiPolicy: aiPolicy,
                additionalFields: additionalFields,
                redisDatabase: connection.redisDatabase,
                startupCommands: connection.startupCommands
            )

            exportableConnections.append(exportable)

            // Collect unique group/tag names
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
            tags: exportableTags
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

    static func exportConnections(_ connections: [DatabaseConnection], to url: URL) throws {
        let envelope = buildEnvelope(for: connections)
        let data = try encode(envelope)

        do {
            try data.write(to: url, options: .atomic)
            logger.info("Exported \(connections.count) connections to \(url.path)")
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
        return try decodeData(data)
    }

    /// Decode an envelope from raw JSON data. Can be called from any thread.
    nonisolated static func decodeData(_ data: Data) throws -> ConnectionExportEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope: ConnectionExportEnvelope
        do {
            envelope = try decoder.decode(ConnectionExportEnvelope.self, from: data)
        } catch {
            throw ConnectionExportError.decodingFailed(error.localizedDescription)
        }

        guard envelope.formatVersion <= currentFormatVersion else {
            throw ConnectionExportError.unsupportedVersion(envelope.formatVersion)
        }

        return envelope
    }

    static func analyzeImport(_ envelope: ConnectionExportEnvelope) -> ConnectionImportPreview {
        let existingConnections = ConnectionStorage.shared.loadConnections()
        let registeredTypeIds = Set(PluginMetadataRegistry.shared.allRegisteredTypeIds())

        let items: [ImportItem] = envelope.connections.map { exportable in
            // Check for duplicate by matching key fields
            let duplicate = existingConnections.first { existing in
                existing.name.lowercased() == exportable.name.lowercased()
                    && existing.host.lowercased() == exportable.host.lowercased()
                    && existing.port == exportable.port
                    && existing.type.rawValue.lowercased() == exportable.type.lowercased()
            }

            if let duplicate {
                return ImportItem(connection: exportable, status: .duplicate(existing: duplicate))
            }

            // Check for warnings
            var warnings: [String] = []

            // SSH key path check
            if let ssh = exportable.sshConfig {
                let keyPath = PathPortability.expandHome(ssh.privateKeyPath)
                if !keyPath.isEmpty, !FileManager.default.fileExists(atPath: keyPath) {
                    warnings.append("SSH private key not found: \(ssh.privateKeyPath)")
                }
                // Jump host key paths
                for jump in ssh.jumpHosts ?? [] {
                    let jumpKeyPath = PathPortability.expandHome(jump.privateKeyPath)
                    if !jumpKeyPath.isEmpty, !FileManager.default.fileExists(atPath: jumpKeyPath) {
                        warnings.append("Jump host key not found: \(jump.privateKeyPath)")
                    }
                }
            }

            // SSL cert paths check
            if let ssl = exportable.sslConfig {
                for (path, label) in [
                    (ssl.caCertificatePath, "CA certificate"),
                    (ssl.clientCertificatePath, "Client certificate"),
                    (ssl.clientKeyPath, "Client key")
                ] {
                    if let path, !path.isEmpty {
                        let expanded = PathPortability.expandHome(path)
                        if !FileManager.default.fileExists(atPath: expanded) {
                            warnings.append("\(label) not found: \(path)")
                        }
                    }
                }
            }

            // Database type check
            if !registeredTypeIds.contains(exportable.type) {
                warnings.append("Database type \"\(exportable.type)\" is not installed")
            }

            if !warnings.isEmpty {
                return ImportItem(connection: exportable, status: .warnings(warnings))
            }

            return ImportItem(connection: exportable, status: .ready)
        }

        return ConnectionImportPreview(envelope: envelope, items: items)
    }

    @discardableResult
    static func performImport(
        _ preview: ConnectionImportPreview,
        resolutions: [UUID: ImportResolution]
    ) -> Int {
        // Create missing groups
        let existingGroups = GroupStorage.shared.loadGroups()
        if let envelopeGroups = preview.envelope.groups {
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

        // Create missing tags
        let existingTags = TagStorage.shared.loadTags()
        if let envelopeTags = preview.envelope.tags {
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

        var importedCount = 0

        for item in preview.items {
            let resolution = resolutions[item.id] ?? .skip
            switch resolution {
            case .skip:
                continue

            case .importNew, .importAsCopy:
                let connectionId = UUID()
                var name = item.connection.name
                if case .importAsCopy = resolution {
                    name += " (Imported)"
                }
                let connection = buildDatabaseConnection(
                    id: connectionId,
                    from: item.connection,
                    name: name
                )
                ConnectionStorage.shared.addConnection(connection, password: nil)
                importedCount += 1

            case .replace(let existingId):
                let connection = buildDatabaseConnection(
                    id: existingId,
                    from: item.connection,
                    name: item.connection.name
                )
                ConnectionStorage.shared.updateConnection(connection, password: nil)
                importedCount += 1
            }
        }

        if importedCount > 0 {
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
            logger.info("Imported \(importedCount) connections")
        }

        return importedCount
    }

    // MARK: - Deeplink Builder

    static func buildImportDeeplink(for connection: DatabaseConnection) -> String {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "name", value: connection.name),
            URLQueryItem(name: "host", value: connection.host),
            URLQueryItem(name: "port", value: String(connection.port)),
            URLQueryItem(name: "type", value: connection.type.rawValue)
        ]

        if !connection.username.isEmpty {
            queryItems.append(URLQueryItem(name: "username", value: connection.username))
        }
        if !connection.database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: connection.database))
        }

        components.queryItems = queryItems

        return components.url?.absoluteString ?? ""
    }

    // MARK: - Private Helpers

    private static func buildDatabaseConnection(
        id: UUID,
        from exportable: ExportableConnection,
        name: String
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
            config.useSSHConfig = ssh.useSSHConfig
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
            TagStorage.shared.loadTags().first { $0.name.lowercased() == name.lowercased() }?.id
        }
        let groupId = exportable.groupName.flatMap { name in
            GroupStorage.shared.loadGroups().first { $0.name.lowercased() == name.lowercased() }?.id
        }

        return DatabaseConnection(
            id: id,
            name: name,
            host: exportable.host,
            port: exportable.port,
            database: exportable.database,
            username: exportable.username,
            type: DatabaseType(rawValue: exportable.type),
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: exportable.color.flatMap { ConnectionColor(rawValue: $0) } ?? .none,
            tagId: tagId,
            groupId: groupId,
            safeModeLevel: exportable.safeModeLevel.flatMap { SafeModeLevel(rawValue: $0) } ?? .silent,
            aiPolicy: exportable.aiPolicy.flatMap { AIConnectionPolicy(rawValue: $0) },
            redisDatabase: exportable.redisDatabase,
            startupCommands: exportable.startupCommands,
            additionalFields: exportable.additionalFields
        )
    }
}
