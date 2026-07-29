import AppIntents
import Foundation
import TableProModels

struct ConnectionEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ConnectionEntity] {
        IntentConnectionLoader.load()
            .filter { identifiers.contains($0.id) }
            .map(ConnectionEntity.init(connection:))
    }

    func suggestedEntities() async throws -> [ConnectionEntity] {
        IntentConnectionLoader.load().map(ConnectionEntity.init(connection:))
    }
}
