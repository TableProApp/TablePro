import Foundation
import os
import TableProDatabase
import TableProImport
import TableProModels

@MainActor
enum IOSConnectionExportService {
    nonisolated enum ExportError: LocalizedError, Equatable {
        case credentialsNeedPassphrase

        var errorDescription: String? {
            switch self {
            case .credentialsNeedPassphrase:
                String(localized: "Set a passphrase to include passwords.")
            }
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSConnectionExport")
    private static let currentFormatVersion = 1

    static func exportData(
        connections: [DatabaseConnection],
        appState: AppState,
        includeCredentials: Bool,
        passphrase: String?
    ) async throws -> Data {
        let envelope = includeCredentials
            ? buildEnvelopeWithCredentials(connections, appState: appState)
            : buildEnvelope(connections, appState: appState)
        return try await fileData(for: envelope, passphrase: includeCredentials ? passphrase : nil)
    }

    static func fileData(for envelope: ConnectionExportEnvelope, passphrase: String?) async throws -> Data {
        let json = try ConnectionImportDecoder.encode(envelope)
        guard let passphrase, !passphrase.isEmpty else {
            guard envelope.credentials == nil else {
                logger.error("Refusing to write saved passwords to a connection file without a passphrase")
                throw ExportError.credentialsNeedPassphrase
            }
            return json
        }
        return try await ConnectionExportCrypto.encrypt(data: json, passphrase: passphrase)
    }

    static func suggestedFilename(for connections: [DatabaseConnection]) -> String {
        if connections.count == 1, let only = connections.first {
            let base = only.name.isEmpty ? only.host : only.name
            return "\(sanitizedFilename(base)).tablepro"
        }
        return "TablePro Connections.tablepro"
    }

    // MARK: - Envelope

    static func buildEnvelope(_ connections: [DatabaseConnection], appState: AppState) -> ConnectionExportEnvelope {
        var groupNames: Set<String> = []
        var tagNames: Set<String> = []

        let exportables: [ExportableConnection] = connections.map { connection in
            let connectionTagNames = connection.tagIds.compactMap { appState.tag(for: $0)?.name }
            let tagName = connectionTagNames.first
            let groupName = appState.group(for: connection.groupId)?.name
            connectionTagNames.forEach { tagNames.insert($0) }
            if let groupName { groupNames.insert(groupName) }

            return ExportableConnection(
                name: connection.name,
                host: connection.host,
                port: connection.port,
                database: connection.database,
                username: connection.username,
                type: connection.type.rawValue,
                sshConfig: exportableSSH(connection),
                sslConfig: exportableSSL(connection),
                color: connection.color == .none ? nil : connection.color.rawValue,
                tagName: tagName,
                tagNames: connectionTagNames.isEmpty ? nil : connectionTagNames,
                groupName: groupName,
                sshProfileId: nil,
                safeModeLevel: connection.safeModeLevel == .off ? nil : connection.safeModeLevel.rawValue,
                aiPolicy: nil,
                additionalFields: connection.additionalFields.isEmpty ? nil : connection.additionalFields,
                redisDatabase: nil,
                startupCommands: nil,
                localOnly: nil
            )
        }

        let exportableGroups: [ExportableGroup]? = groupNames.isEmpty ? nil : groupNames.map { name in
            let color = appState.groups.first { $0.name == name }?.color
            return ExportableGroup(name: name, color: color == .none ? nil : color?.rawValue)
        }
        let exportableTags: [ExportableTag]? = tagNames.isEmpty ? nil : tagNames.map { name in
            let color = appState.tags.first { $0.name == name }?.color
            return ExportableTag(name: name, color: color == .none ? nil : color?.rawValue)
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        return ConnectionExportEnvelope(
            formatVersion: currentFormatVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            connections: exportables,
            groups: exportableGroups,
            tags: exportableTags,
            credentials: nil
        )
    }

    static func buildEnvelopeWithCredentials(
        _ connections: [DatabaseConnection],
        appState: AppState
    ) -> ConnectionExportEnvelope {
        let base = buildEnvelope(connections, appState: appState)
        let store = appState.secureStore

        var credentialsMap: [String: ExportableCredentials] = [:]
        for (index, connection) in connections.enumerated() {
            let password = secret(.password, of: connection.id, from: store)
            let sshPassword = secret(.sshPassword, of: connection.id, from: store)
            let keyPassphrase = secret(.keyPassphrase, of: connection.id, from: store)

            guard password != nil || sshPassword != nil || keyPassphrase != nil else { continue }
            credentialsMap[String(index)] = ExportableCredentials(
                password: password,
                sshPassword: sshPassword,
                keyPassphrase: keyPassphrase,
                sslClientKeyPassphrase: nil,
                totpSecret: nil,
                pluginSecureFields: nil
            )
        }

        return ConnectionExportEnvelope(
            formatVersion: base.formatVersion,
            exportedAt: base.exportedAt,
            appVersion: base.appVersion,
            connections: base.connections,
            groups: base.groups,
            tags: base.tags,
            credentials: credentialsMap.isEmpty ? nil : credentialsMap
        )
    }

    // MARK: - Helpers

    private static func secret(
        _ kind: ConnectionSecretKind,
        of connectionId: UUID,
        from store: any SecureStore
    ) -> String? {
        (try? store.retrieve(forKey: kind.account(for: connectionId))) ?? nil
    }

    private static func exportableSSH(_ connection: DatabaseConnection) -> ExportableSSHConfig? {
        guard connection.sshEnabled, let ssh = connection.sshConfiguration else { return nil }
        let jumpHosts: [ExportableJumpHost]? = ssh.jumpHosts.isEmpty ? nil : ssh.jumpHosts.map {
            ExportableJumpHost(
                host: $0.host,
                port: $0.port,
                username: $0.username,
                authMethod: $0.macAuthMethod,
                privateKeyPath: $0.macPrivateKeyPath
            )
        }
        return ExportableSSHConfig(
            enabled: true,
            host: ssh.host,
            port: ssh.port,
            username: ssh.username,
            authMethod: ssh.authMethod.rawValue,
            privateKeyPath: PathPortability.contractHome(ssh.privateKeyPath ?? ""),
            agentSocketPath: "",
            jumpHosts: jumpHosts,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private static func exportableSSL(_ connection: DatabaseConnection) -> ExportableSSLConfig? {
        guard connection.sslEnabled, let ssl = connection.sslConfiguration, ssl.mode != .disable else { return nil }
        return ExportableSSLConfig(
            mode: ssl.mode.rawValue,
            caCertificatePath: PathPortability.contractHome(ssl.caCertificatePath ?? ""),
            clientCertificatePath: PathPortability.contractHome(ssl.clientCertificatePath ?? ""),
            clientKeyPath: PathPortability.contractHome(ssl.clientKeyPath ?? "")
        )
    }

    private static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Connection" : cleaned
    }
}
