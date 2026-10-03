import Foundation
import TableProModels

nonisolated struct ConnectionFileDetail: Equatable, Sendable {
    let name: String
    let path: String?
}

nonisolated enum ConnectionInfoSection: Equatable, Sendable {
    case server
    case file(ConnectionFileDetail)
}

nonisolated enum ConnectionInfoContent {
    static func section(for connection: DatabaseConnection, fileURL: URL?) -> ConnectionInfoSection {
        guard connection.type.isLocalFile else { return .server }
        guard connection.database != LocalDatabaseLocation.inMemoryPath else {
            return .file(ConnectionFileDetail(name: String(localized: "In Memory"), path: nil))
        }
        return .file(ConnectionFileDetail(
            name: fileURL?.lastPathComponent ?? connection.database,
            path: fileURL?.path ?? connection.database
        ))
    }
}
