import Foundation
import TableProConnectionLibrary
import TableProDatabase
import TableProImport
import TableProModels

@MainActor
enum IOSConnectionExportService {
    static func exportData(
        connections: [DatabaseConnection],
        appState: AppState,
        includeCredentials: Bool,
        passphrase: String?
    ) async throws -> Data {
        let bundle = try BundleExportAssembler.assemble(
            exportInput(connections, appState: appState, includeCredentials: includeCredentials),
            options: BundleExportOptions(includesCredentials: includeCredentials, includesSavedQueries: false),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        return try await ConnectionBundleCodec.encode(bundle, passphrase: includeCredentials ? passphrase ?? "" : "")
    }

    static func suggestedFilename(for connections: [DatabaseConnection]) -> String {
        if connections.count == 1, let only = connections.first {
            let base = only.name.isEmpty ? only.host : only.name
            return "\(sanitizedFilename(base)).tablepro"
        }
        return "TablePro Connections.tablepro"
    }

    static func portableSettings(for connection: DatabaseConnection) -> ExportableConnection {
        ExportableConnection(
            name: connection.name,
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type.rawValue,
            sshConfig: portableSSH(connection),
            sslConfig: portableSSL(connection),
            color: connection.color == .none ? nil : connection.color.rawValue,
            iconName: LibrarySymbolCatalog.normalizedName(connection.iconName),
            safeModeLevel: connection.safeModeLevel == .off ? nil : connection.safeModeLevel.rawValue,
            connectTimeoutSeconds: connection.connectTimeoutSeconds,
            queryTimeoutSeconds: connection.queryTimeoutSeconds.flatMap {
                DatabaseConnection.queryTimeoutSecondsRange.contains($0) ? $0 : nil
            },
            additionalFields: portableAdditionalFields(connection)
        )
    }

    private static func exportInput(
        _ connections: [DatabaseConnection],
        appState: AppState,
        includeCredentials: Bool
    ) -> BundleExportInput {
        BundleExportInput(
            connections: connections.map { connection in
                BundleExportInput.Connection(
                    id: connection.id,
                    settings: portableSettings(for: connection),
                    groupId: connection.groupId,
                    tagIds: connection.tagIds,
                    credentials: includeCredentials ? credentials(of: connection.id, in: appState.secureStore) : nil
                )
            },
            groups: appState.groups.map {
                BundleExportInput.Group(
                    id: $0.id,
                    name: $0.name,
                    color: portableColor($0.color),
                    iconName: LibrarySymbolCatalog.normalizedName($0.iconName),
                    parentId: $0.parentId
                )
            },
            tags: appState.tags.map {
                BundleExportInput.Tag(id: $0.id, name: $0.name, color: portableColor($0.color))
            }
        )
    }

    private static func credentials(of connectionId: UUID, in store: any SecureStore) -> ExportableCredentials? {
        let password = secret(.password, of: connectionId, in: store)
        let sshPassword = secret(.sshPassword, of: connectionId, in: store)
        let keyPassphrase = secret(.keyPassphrase, of: connectionId, in: store)
        guard password != nil || sshPassword != nil || keyPassphrase != nil else { return nil }
        return ExportableCredentials(
            password: password,
            sshPassword: sshPassword,
            keyPassphrase: keyPassphrase,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    private static func secret(_ kind: ConnectionSecretKind, of connectionId: UUID, in store: any SecureStore) -> String? {
        (try? store.retrieve(forKey: kind.account(for: connectionId))) ?? nil
    }

    private static func portableColor(_ color: ConnectionColor) -> String? {
        color == .none ? nil : color.rawValue
    }

    private static func portableAdditionalFields(_ connection: DatabaseConnection) -> [String: String]? {
        var fields = connection.additionalFields
        fields.removeValue(forKey: DatabaseConnection.connectTimeoutSecondsKey)
        fields.removeValue(forKey: DatabaseConnection.queryTimeoutSecondsKey)
        return ExportableConnection.shareableAdditionalFields(fields)
    }

    private static func portableSSH(_ connection: DatabaseConnection) -> ExportableSSHConfig? {
        guard connection.sshEnabled, let ssh = connection.sshConfiguration else { return nil }
        let jumpHosts: [ExportableJumpHost]? = ssh.jumpHosts.isEmpty ? nil : ssh.jumpHosts.map {
            ExportableJumpHost(
                host: $0.host,
                port: $0.port,
                username: $0.username,
                authMethod: $0.macAuthMethod.rawValue,
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

    private static func portableSSL(_ connection: DatabaseConnection) -> ExportableSSLConfig? {
        guard connection.sslEnabled, let ssl = connection.sslConfiguration, ssl.mode != .disable else { return nil }
        return ExportableSSLConfig(
            mode: ssl.mode.portableMode.rawValue,
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

internal extension SSLConfiguration.SSLMode {
    var portableMode: PortableSSLMode {
        switch self {
        case .disable: .disabled
        case .require: .required
        case .verifyCa: .verifyCA
        case .verifyFull: .verifyIdentity
        }
    }
}
