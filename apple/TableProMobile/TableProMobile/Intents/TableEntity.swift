import AppIntents
import Foundation
import TableProDatabase
import TableProModels

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

// A dependency that lists the optional database stays nil until one is picked, and SQLite never offers one.
struct TableEntityQuery: EntityQuery {
    @IntentParameterDependency<AddRowToTableIntent>(\.$connection)
    var addRow

    @IntentParameterDependency<AddRowToTableIntent>(\.$connection, \.$database)
    var addRowInDatabase

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection)
    var addRows

    @IntentParameterDependency<AddRowsToTableIntent>(\.$connection, \.$database)
    var addRowsInDatabase

    @Dependency private var lockState: AppLockState

    func entities(for identifiers: [String]) async throws -> [TableEntity] {
        identifiers.map { TableEntity(id: $0, name: $0) }
    }

    func suggestedEntities() async throws -> [TableEntity] {
        try await Self.tables(in: selectedScope, lock: lockState)
    }

    // Throws instead of listing nothing: the picker shows the error, so a failed open never reads as no tables.
    static func tables(
        in scope: TableListingScope?,
        lock: AppLockState,
        keychain: any SecureStore = KeychainSecureStore(),
        savedConnection: @Sendable (UUID) -> DatabaseConnection? = IntentConnectionLoader.connection(id:)
    ) async throws -> [TableEntity] {
        guard let scope else { return [] }
        return try await IntentDatabaseSession.with(
            connectionId: scope.connectionId,
            lock: lock,
            keychain: keychain,
            savedConnection: savedConnection
        ) {
            try await $0.tables(namespace: scope.namespace)
        }
    }

    private var selectedScope: TableListingScope? {
        let scoped = addRowInDatabase.map { (connection: $0.connection, database: $0.database) }
            ?? addRowsInDatabase.map { (connection: $0.connection, database: $0.database) }
        return TableListingScope.resolve(scoped: scoped, connection: addRow?.connection ?? addRows?.connection)
    }
}
