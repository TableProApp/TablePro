import Foundation
import TableProModels
import TableProPluginKit

nonisolated struct ConnectionFileDetail: Equatable, Sendable {
    let name: String
    let path: String?
}

nonisolated struct ConnectionAccountDetail: Equatable, Sendable {
    let accountId: String?
}

nonisolated enum ConnectionInfoSection: Equatable, Sendable {
    case server
    case file(ConnectionFileDetail)
    // An engine reached through a web API: no host, port, SSL or SSH to show.
    case account(ConnectionAccountDetail)
}

nonisolated enum ConnectionInfoContent {
    static func section(for connection: DatabaseConnection, fileURL: URL?) -> ConnectionInfoSection {
        switch connection.type.connectionMode {
        case .network:
            return .server
        case .apiOnly:
            let accountId = connection.additionalFields[CloudflareD1Plugin.accountIdFieldId]
            return .account(ConnectionAccountDetail(accountId: accountId?.isEmpty == false ? accountId : nil))
        case .fileBased:
            guard connection.database != LocalDatabaseLocation.inMemoryPath else {
                return .file(ConnectionFileDetail(name: String(localized: "In Memory"), path: nil))
            }
            return .file(ConnectionFileDetail(
                name: fileURL?.lastPathComponent ?? connection.database,
                path: fileURL?.path ?? connection.database
            ))
        }
    }
}
