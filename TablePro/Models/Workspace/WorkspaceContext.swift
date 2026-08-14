import Foundation

// Note: This file is part of the new Database Context Rail feature.
// It defines the core WorkspaceContextKey and related types.
// See docs/superpowers/plans/2026-08-04-database-context-rail.md for details.

internal struct WorkspaceContextKey: Codable, Hashable, Identifiable {
    internal let connectionId: UUID
    internal let databaseName: String
    internal let schemaName: String?

    internal var id: String { tabbingIdentifier }

    internal var tabbingIdentifier: String {
        let database = Self.identifierComponent(databaseName)
        let schema = schemaName.map(Self.identifierComponent) ?? "_"
        return "com.TablePro.main.context.\(connectionId.uuidString).\(database).\(schema)"
    }

    internal static func resolve(
        connection: DatabaseConnection,
        databaseName: String?,
        schemaName: String?,
        activeDatabase: String?,
        activeSchema: String?,
        supportsSchemaSwitching: Bool
    ) -> WorkspaceContextKey {
        let database = nonBlank(databaseName)
            ?? nonBlank(activeDatabase)
            ?? nonBlank(connection.database)
            ?? connection.name
        let schema = supportsSchemaSwitching
            ? nonBlank(schemaName) ?? nonBlank(activeSchema)
            : nil
        return WorkspaceContextKey(
            connectionId: connection.id,
            databaseName: database,
            schemaName: schema
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func identifierComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

internal struct WorkspaceContextDescriptor: Identifiable, Equatable {
    internal let key: WorkspaceContextKey
    internal let connectionName: String
    internal let databaseType: DatabaseType
    internal let connectionColor: ConnectionColor
    internal var isConnected: Bool

    internal var id: WorkspaceContextKey { key }
    internal var displayName: String { key.schemaName ?? key.databaseName }

    internal var fullPath: String {
        [connectionName, key.databaseName, key.schemaName]
            .compactMap { $0 }
            .joined(separator: " / ")
    }
}
