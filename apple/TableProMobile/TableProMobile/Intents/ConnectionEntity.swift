import AppIntents
import Foundation
import TableProModels

struct ConnectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Connection")
    static let defaultQuery = ConnectionEntityQuery()

    var id: UUID
    var name: String
    var host: String
    var databaseType: String
    // The connection list's line, so an engine without a host names its file or database instead.
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(databaseType), \(detail)"
        )
    }

    init(id: UUID, name: String, host: String, databaseType: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.databaseType = databaseType
        self.detail = detail ?? host
    }

    init(connection: DatabaseConnection) {
        self.init(
            id: connection.id,
            name: connection.name.isEmpty ? connection.host : connection.name,
            host: connection.host,
            databaseType: connection.type.rawValue,
            detail: ConnectionDetailFormatter.detail(for: connection)
        )
    }
}
