import Foundation

struct ToolConnectionMetadata {
    let databaseType: DatabaseType
    let safeModeLevel: SafeModeLevel
    let databaseName: String

    static func resolve(connectionId: UUID) async throws -> ToolConnectionMetadata {
        try await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live(_, let session):
                return ToolConnectionMetadata(
                    databaseType: session.connection.type,
                    safeModeLevel: session.connection.safeModeLevel,
                    databaseName: session.activeDatabase
                )
            case .stored(let conn):
                return ToolConnectionMetadata(
                    databaseType: conn.type,
                    safeModeLevel: conn.safeModeLevel,
                    databaseName: conn.database
                )
            case .unknown:
                throw MCPProtocolError.invalidParams(detail: "Connection not found: \(connectionId.uuidString)")
            }
        }
    }
}
