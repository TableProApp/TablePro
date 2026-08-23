import Foundation

struct ToolConnectionMetadata: Sendable {
    let connectionId: UUID
    let databaseType: DatabaseType
    let safeModeLevel: SafeModeLevel
    let externalAccess: ExternalAccessLevel
    let databaseName: String
    let connectionName: String
    let redactionSecrets: [String]

    static func resolve(connectionId: UUID) async throws -> ToolConnectionMetadata {
        try await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live(_, let session):
                return make(
                    connectionId: connectionId,
                    connection: session.connection,
                    databaseName: session.resolvedBrowseDatabase
                )
            case .stored(let connection):
                return make(
                    connectionId: connectionId,
                    connection: connection,
                    databaseName: connection.database
                )
            case .unknown:
                throw MCPToolExecutionError.notFound(
                    String(localized: "No saved connection has that id.")
                )
            }
        }
    }

    @MainActor
    private static func make(
        connectionId: UUID,
        connection: DatabaseConnection,
        databaseName: String
    ) -> ToolConnectionMetadata {
        ToolConnectionMetadata(
            connectionId: connectionId,
            databaseType: connection.type,
            safeModeLevel: connection.safeModeLevel,
            externalAccess: connection.externalAccess,
            databaseName: databaseName,
            connectionName: connection.name,
            redactionSecrets: [
                connection.host,
                connection.username,
                connection.database,
                String(connection.port)
            ].filter { !$0.isEmpty }
        )
    }
}
