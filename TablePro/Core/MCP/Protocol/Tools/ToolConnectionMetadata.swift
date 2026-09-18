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
            do {
                return make(try ExternalConnectionPolicySnapshot.resolve(connectionId: connectionId))
            } catch {
                throw MCPToolExecutionError.notFound(
                    String(localized: "No saved connection has that id.")
                )
            }
        }
    }

    @MainActor
    private static func make(_ snapshot: ExternalConnectionPolicySnapshot) -> ToolConnectionMetadata {
        ToolConnectionMetadata(
            connectionId: snapshot.connectionId,
            databaseType: snapshot.databaseType,
            safeModeLevel: snapshot.safeModeLevel,
            externalAccess: snapshot.externalAccess,
            databaseName: snapshot.databaseName,
            connectionName: snapshot.connectionName,
            redactionSecrets: [
                snapshot.host,
                snapshot.username,
                snapshot.storedDatabaseName,
                String(snapshot.port)
            ].filter { !$0.isEmpty }
        )
    }
}
