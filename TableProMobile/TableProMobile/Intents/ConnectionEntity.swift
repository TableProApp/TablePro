import AppIntents
import Foundation

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
}
