import Foundation

/// Persists user-arranged table node positions for ER diagrams.
/// Keyed by connection + schema so positions survive across sessions.
@MainActor
final class ERDiagramPositionStorage {
    static let shared = ERDiagramPositionStorage()
    private let defaults = AppStorageEnvironment.shared.defaults

    private init() {}

    private func key(connectionId: UUID, schemaKey: String) -> String {
        "com.TablePro.erDiagram.positions.\(connectionId.uuidString).\(schemaKey)"
    }

    func load(connectionId: UUID, schemaKey: String) -> [String: CGPoint] {
        guard let data = defaults.data(forKey: key(connectionId: connectionId, schemaKey: schemaKey)),
              let stored = try? JSONDecoder().decode([String: CodablePoint].self, from: data)
        else { return [:] }
        return stored.mapValues { CGPoint(x: $0.x, y: $0.y) }
    }

    func save(_ positions: [String: CGPoint], connectionId: UUID, schemaKey: String) {
        let stored = positions.mapValues { CodablePoint(x: $0.x, y: $0.y) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key(connectionId: connectionId, schemaKey: schemaKey))
    }

    func clear(connectionId: UUID, schemaKey: String) {
        defaults.removeObject(forKey: key(connectionId: connectionId, schemaKey: schemaKey))
    }
}

private struct CodablePoint: Codable {
    let x: Double
    let y: Double
}
