//
//  TableEntity.swift
//  TablePro
//

import AppIntents
import Foundation

@available(macOS 14.0, *)
internal struct TableEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Table")
    static let defaultQuery = TableEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

// A dependency hands back every parameter it lists unwrapped, so one that lists the optional database stays nil
// until a database is picked. SQLite never offers one, hence the connection-only dependencies too.
@available(macOS 14.0, *)
internal struct TableEntityQuery: EntityQuery {
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
        let scoped = addRowInDatabase.map { (connection: $0.connection, database: $0.database) }
            ?? addRowsInDatabase.map { (connection: $0.connection, database: $0.database) }
        guard let connection = scoped?.connection ?? addRow?.connection ?? addRows?.connection else { return [] }
        do {
            return try await ShortcutsCatalog.tables(connectionId: connection.id, namespace: scoped?.database.id)
                .map { TableEntity(id: $0, name: $0) }
        } catch {
            throw ShortcutsActionError.wrapping(error)
        }
    }
}
