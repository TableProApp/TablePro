import AppIntents
import Foundation
import TableProModels

struct ConnectionEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Connection")
    static var defaultQuery = ConnectionEntityQuery()

    var id: UUID
    var name: String
    var host: String
    var databaseType: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(databaseType) · \(host)"
        )
    }

    init(id: UUID, name: String, host: String, databaseType: String) {
        self.id = id
        self.name = name
        self.host = host
        self.databaseType = databaseType
    }

    init(connection: DatabaseConnection) {
        self.init(
            id: connection.id,
            name: connection.name.isEmpty ? connection.host : connection.name,
            host: connection.host,
            databaseType: connection.type.rawValue
        )
    }
}
