import Foundation

// MARK: - Import Preview Types

public enum ImportItemStatus {
    case ready
    case duplicate(existingId: UUID, existingName: String)
    case warnings([String])
}

public struct ImportItem: Identifiable {
    public let id = UUID()
    public let connection: ExportableConnection
    public let status: ImportItemStatus

    public init(connection: ExportableConnection, status: ImportItemStatus) {
        self.connection = connection
        self.status = status
    }
}

public enum ImportResolution: Hashable {
    case importNew
    case skip
    case replace(existingId: UUID)
    case importAsCopy
}

public struct ConnectionImportPreview {
    public let envelope: ConnectionExportEnvelope
    public let items: [ImportItem]

    public init(envelope: ConnectionExportEnvelope, items: [ImportItem]) {
        self.envelope = envelope
        self.items = items
    }
}

public struct ConnectionDuplicateCandidate {
    public let id: UUID
    public let name: String
    public let host: String
    public let port: Int
    public let database: String
    public let username: String
    public let redisDatabase: Int?

    public init(
        id: UUID,
        name: String,
        host: String,
        port: Int,
        database: String,
        username: String,
        redisDatabase: Int?
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.redisDatabase = redisDatabase
    }
}

// MARK: - Import Analyzer

public enum ConnectionImportAnalyzer {
    public static func analyze(
        _ envelope: ConnectionExportEnvelope,
        existingConnections: [ConnectionDuplicateCandidate],
        registeredTypeIds: Set<String>,
        fileExists: (String) -> Bool
    ) -> ConnectionImportPreview {
        var duplicateMap: [ConnectionImportDuplicateKey: ConnectionDuplicateCandidate] = [:]
        for existing in existingConnections {
            let key = duplicateKey(for: existing)
            if duplicateMap[key] == nil {
                duplicateMap[key] = existing
            }
        }

        let items: [ImportItem] = envelope.connections.map { exportable in
            if let duplicate = duplicateMap[duplicateKey(for: exportable)] {
                return ImportItem(
                    connection: exportable,
                    status: .duplicate(existingId: duplicate.id, existingName: duplicate.name)
                )
            }

            var warnings: [String] = []

            if let ssh = exportable.sshConfig {
                let keyPath = PathPortability.expandHome(ssh.privateKeyPath)
                if !keyPath.isEmpty, !fileExists(keyPath) {
                    warnings.append(String(
                        format: String(localized: "SSH private key not found: %@"),
                        ssh.privateKeyPath
                    ))
                }
                for jump in ssh.jumpHosts ?? [] {
                    let jumpKeyPath = PathPortability.expandHome(jump.privateKeyPath)
                    if !jumpKeyPath.isEmpty, !fileExists(jumpKeyPath) {
                        warnings.append(String(
                            format: String(localized: "Jump host key not found: %@"),
                            jump.privateKeyPath
                        ))
                    }
                }
            }

            if let ssl = exportable.sslConfig {
                for (path, format) in [
                    (ssl.caCertificatePath, String(localized: "CA certificate not found: %@")),
                    (ssl.clientCertificatePath, String(localized: "Client certificate not found: %@")),
                    (ssl.clientKeyPath, String(localized: "Client key not found: %@"))
                ] {
                    if let path, !path.isEmpty {
                        let expanded = PathPortability.expandHome(path)
                        if !fileExists(expanded) {
                            warnings.append(String(format: format, path))
                        }
                    }
                }
            }

            if !registeredTypeIds.contains(exportable.type) {
                warnings.append(String(
                    format: String(localized: "Database type \"%@\" is not installed"),
                    exportable.type
                ))
            }

            if !warnings.isEmpty {
                return ImportItem(connection: exportable, status: .warnings(warnings))
            }

            return ImportItem(connection: exportable, status: .ready)
        }

        return ConnectionImportPreview(envelope: envelope, items: items)
    }

    // MARK: - Duplicate Keys

    private struct ConnectionImportDuplicateKey: Hashable {
        let components: [String]
    }

    private static func duplicateKey(for connection: ExportableConnection) -> ConnectionImportDuplicateKey {
        ConnectionImportDuplicateKey(
            components: [
                normalizedLookupKey(connection.host),
                String(connection.port),
                effectiveDatabaseKey(database: connection.database, redisDatabase: connection.redisDatabase),
                normalizedLookupKey(connection.username)
            ]
        )
    }

    private static func duplicateKey(for candidate: ConnectionDuplicateCandidate) -> ConnectionImportDuplicateKey {
        ConnectionImportDuplicateKey(
            components: [
                normalizedLookupKey(candidate.host),
                String(candidate.port),
                effectiveDatabaseKey(database: candidate.database, redisDatabase: candidate.redisDatabase),
                normalizedLookupKey(candidate.username)
            ]
        )
    }

    private static func effectiveDatabaseKey(database: String?, redisDatabase: Int?) -> String {
        let normalized = normalizedLookupKey(database)
        if !normalized.isEmpty {
            return normalized
        }
        if let redisDatabase {
            return String(redisDatabase)
        }
        return ""
    }

    private static func normalizedLookupKey(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

// MARK: - Import Decoder

public enum ConnectionImportDecoder {
    public static let currentFormatVersion = 1

    public static func decodeData(_ data: Data) throws -> ConnectionExportEnvelope {
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

        return ConnectionExportEnvelope(
            formatVersion: envelope.formatVersion,
            exportedAt: envelope.exportedAt,
            appVersion: envelope.appVersion,
            connections: envelope.connections.map { $0.sanitizedForImport() },
            groups: envelope.groups,
            tags: envelope.tags,
            credentials: envelope.credentials
        )
    }

    public static func decodeEncryptedData(_ data: Data, passphrase: String) throws -> ConnectionExportEnvelope {
        let decryptedData: Data
        do {
            decryptedData = try ConnectionExportCrypto.decrypt(data: data, passphrase: passphrase)
        } catch {
            throw ConnectionExportError.decryptionFailed(error.localizedDescription)
        }
        return try decodeData(decryptedData)
    }

    public static func encode(_ envelope: ConnectionExportEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(envelope)
        } catch {
            throw ConnectionExportError.encodingFailed
        }
    }
}
