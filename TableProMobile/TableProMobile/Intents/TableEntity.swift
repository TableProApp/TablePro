import AppIntents
import Foundation

struct TableEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Table")
    static let defaultQuery = TableEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct TableListingScope: Equatable, Sendable {
    let connectionId: UUID
    let namespace: String?

    static func resolve(
        scoped: (connection: ConnectionEntity, database: DatabaseEntity)?,
        connection: ConnectionEntity?
    ) -> TableListingScope? {
        if let scoped {
            return TableListingScope(connectionId: scoped.connection.id, namespace: scoped.database.id)
        }
        guard let connection else { return nil }
        return TableListingScope(connectionId: connection.id, namespace: nil)
    }
}

/// A dependency hands back every parameter it lists unwrapped, so one that lists the optional
/// database stays nil until a database is picked. SQLite never offers one, hence the separate
/// connection-only dependencies.
struct TableEntityQuery: EntityQuery {
    @IntentParameterDependency<AddRowToTableIntent>(\.$connection)
    var addRow

    @IntentParameterDependency<AddRowToTableIntent>(\.$connection, \.$database)
    var addRowInDatabase

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection)
    var addRows

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection, \.$database)
    var addRowsInDatabase

    func entities(for identifiers: [String]) async throws -> [TableEntity] {
        identifiers.map { TableEntity(id: $0, name: $0) }
    }

    func suggestedEntities() async throws -> [TableEntity] {
        guard let scope = selectedScope else { return [] }
        let tables = try? await IntentDatabaseSession.with(connectionId: scope.connectionId) {
            try await $0.tables(namespace: scope.namespace)
        }
        return tables ?? []
    }

    private var selectedScope: TableListingScope? {
        let scoped = addRowInDatabase.map { (connection: $0.connection, database: $0.database) }
            ?? addRowsInDatabase.map { (connection: $0.connection, database: $0.database) }
        return TableListingScope.resolve(scoped: scoped, connection: addRow?.connection ?? addRows?.connection)
    }
}
