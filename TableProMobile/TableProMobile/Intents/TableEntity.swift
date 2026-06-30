import AppIntents
import Foundation

struct TableEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Table")
    static var defaultQuery = TableEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct TableEntityQuery: EntityQuery {
    @IntentParameterDependency<AddRowToTableIntent>(\.$connection, \.$database)
    var addRow

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection, \.$database)
    var addRows

    func entities(for identifiers: [String]) async throws -> [TableEntity] {
        identifiers.map { TableEntity(id: $0, name: $0) }
    }

    func suggestedEntities() async throws -> [TableEntity] {
        guard let context = selectedContext else { return [] }
        let tables = try? await IntentDatabaseSession.with(connectionId: context.connection.id) {
            try await $0.tables(namespace: context.database?.id)
        }
        return tables ?? []
    }

    private var selectedContext: (connection: ConnectionEntity, database: DatabaseEntity?)? {
        if let addRow {
            return (addRow.connection, addRow.database)
        }
        if let addRows {
            return (addRows.connection, addRows.database)
        }
        return nil
    }
}
