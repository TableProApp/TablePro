import Foundation
import TableProImport

enum RDSDiscoveryReconciler {
    struct ExistingEndpoint: Sendable, Equatable {
        let host: String
        let port: Int
        let database: String
        let username: String

        init(host: String, port: Int, database: String, username: String) {
            self.host = host
            self.port = port
            self.database = database
            self.username = username
        }
    }

    static func adoptingExistingIdentity(
        _ connections: [ExportableConnection],
        existing: [ExistingEndpoint]
    ) -> [ExportableConnection] {
        guard !existing.isEmpty else { return connections }
        var byEndpoint: [String: ExistingEndpoint] = [:]
        var ambiguous: Set<String> = []
        for endpoint in existing {
            let key = endpointKey(host: endpoint.host, port: endpoint.port)
            if byEndpoint.updateValue(endpoint, forKey: key) != nil {
                ambiguous.insert(key)
            }
        }

        return connections.map { connection in
            let key = endpointKey(host: connection.host, port: connection.port)
            guard !ambiguous.contains(key), let match = byEndpoint[key] else {
                return connection
            }
            let database = connection.database.isEmpty ? match.database : connection.database
            return connection.identified(username: match.username, database: database)
        }
    }

    static func envelope(for connections: [ExportableConnection]) -> ConnectionExportEnvelope {
        ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "AWS Import",
            connections: connections,
            groups: nil,
            tags: nil,
            credentials: nil
        )
    }

    static func markingMissingDrivers(
        _ preview: ConnectionImportPreview,
        missingDriverName: (String) -> String?
    ) -> ConnectionImportPreview {
        let items = preview.items.map { item -> ImportItem in
            guard case .ready = item.status, let pluginName = missingDriverName(item.connection.type) else {
                return item
            }
            let warning = String(
                format: String(localized: "The %@ plugin is not installed. TablePro offers to install it on connect."),
                pluginName
            )
            return ImportItem(connection: item.connection, status: .warnings([warning]))
        }
        return ConnectionImportPreview(envelope: preview.envelope, items: items)
    }

    private static func endpointKey(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(port)"
    }
}

private extension ExportableConnection {
    func identified(username: String, database: String) -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: color,
            tagName: tagName,
            tagNames: tagNames,
            groupName: groupName,
            sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel,
            aiPolicy: aiPolicy,
            additionalFields: additionalFields,
            redisDatabase: redisDatabase,
            startupCommands: startupCommands,
            localOnly: localOnly,
            tunnelCommand: tunnelCommand
        )
    }
}
