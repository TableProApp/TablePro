import AppIntents
import Foundation

struct ConnectionEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ConnectionEntity] {
        let all = loadConnections()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ConnectionEntity] {
        loadConnections()
    }

    private func loadConnections() -> [ConnectionEntity] {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }
        let fileURL = dir
            .appendingPathComponent("TableProMobile", isDirectory: true)
            .appendingPathComponent("connections.json")
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        struct StoredConnection: Decodable {
            let id: UUID
            let name: String
            let host: String
            let type: String
        }

        guard let connections = try? JSONDecoder().decode([StoredConnection].self, from: data) else {
            return []
        }

        return connections.map { conn in
            ConnectionEntity(
                id: conn.id,
                name: conn.name.isEmpty ? conn.host : conn.name,
                host: conn.host,
                databaseType: conn.type
            )
        }
    }
}
