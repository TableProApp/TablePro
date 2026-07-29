import AppIntents
import Foundation

struct DatabaseEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Database or Schema")
    static var defaultQuery = DatabaseEntityQuery()

    var id: String
    var name: String
    var kind: Kind

    enum Kind: String, Sendable {
        case database
        case schema
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct DatabaseEntityQuery: EntityQuery {
    @IntentParameterDependency<AddRowToTableIntent>(\.$connection)
    var addRow

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection)
    var addRows

    func entities(for identifiers: [String]) async throws -> [DatabaseEntity] {
        identifiers.map { DatabaseEntity(id: $0, name: $0, kind: .database) }
    }

    func suggestedEntities() async throws -> [DatabaseEntity] {
        guard let connection = selectedConnection else { return [] }
        let namespaces = try? await IntentDatabaseSession.with(connectionId: connection.id) {
            try await $0.namespaces()
        }
        return namespaces ?? []
    }

    private var selectedConnection: ConnectionEntity? {
        addRow?.connection ?? addRows?.connection
    }
}
