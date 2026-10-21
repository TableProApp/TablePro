//
//  DatabaseEntity.swift
//  TablePro
//

import AppIntents
import Foundation

@available(macOS 14.0, *)
internal struct DatabaseEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Database or Schema")
    static let defaultQuery = DatabaseEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

@available(macOS 14.0, *)
internal struct DatabaseEntityQuery: EntityQuery {
    @IntentParameterDependency<RunQueryIntent>(\.$connection)
    var runQuery

    @IntentParameterDependency<AddRowToTableIntent>(\.$connection)
    var addRow

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection)
    var addRows

    func entities(for identifiers: [String]) async throws -> [DatabaseEntity] {
        identifiers.map { DatabaseEntity(id: $0, name: $0) }
    }

    // Throws rather than listing nothing: the picker shows the error, so a connection that cannot open does not read
    // as a server with no databases.
    func suggestedEntities() async throws -> [DatabaseEntity] {
        guard let connection = runQuery?.connection ?? addRow?.connection ?? addRows?.connection else { return [] }
        do {
            return try await ShortcutsCatalog.namespaces(connectionId: connection.id)
                .map { DatabaseEntity(id: $0, name: $0) }
        } catch {
            throw ShortcutsActionError.wrapping(error)
        }
    }
}
