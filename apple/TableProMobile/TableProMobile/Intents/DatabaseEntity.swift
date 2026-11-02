import AppIntents
import Foundation
import TableProDatabase
import TableProModels

struct DatabaseEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Database or Schema")
    static let defaultQuery = DatabaseEntityQuery()

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

    @Dependency private var lockState: AppLockState

    func entities(for identifiers: [String]) async throws -> [DatabaseEntity] {
        identifiers.map { DatabaseEntity(id: $0, name: $0, kind: .database) }
    }

    func suggestedEntities() async throws -> [DatabaseEntity] {
        try await Self.namespaces(of: selectedConnection?.id, lock: lockState)
    }

    // Throws instead of listing nothing: an empty list would read as a server with no databases.
    static func namespaces(
        of connectionId: UUID?,
        lock: AppLockState,
        keychain: any SecureStore = KeychainSecureStore(),
        savedConnection: @Sendable (UUID) -> DatabaseConnection? = IntentConnectionLoader.connection(id:)
    ) async throws -> [DatabaseEntity] {
        guard let connectionId else { return [] }
        return try await IntentDatabaseSession.with(
            connectionId: connectionId,
            lock: lock,
            keychain: keychain,
            savedConnection: savedConnection
        ) {
            try await $0.namespaces()
        }
    }

    private var selectedConnection: ConnectionEntity? {
        addRow?.connection ?? addRows?.connection
    }
}
