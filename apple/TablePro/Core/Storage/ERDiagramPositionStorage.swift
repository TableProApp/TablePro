import Foundation

@MainActor
final class ERDiagramPositionStorage {
    static let shared = ERDiagramPositionStorage()
    private let defaults = AppStorageEnvironment.shared.defaults

    private init() {}

    private func key(connectionId: UUID, schemaKey: String) -> JSONDefaultsKey<[String: CodablePoint]> {
        JSONDefaultsKey("com.TablePro.erDiagram.positions.\(connectionId.uuidString).\(schemaKey)")
    }

    func load(connectionId: UUID, schemaKey: String) -> [String: CGPoint] {
        let stored = defaults.read(key(connectionId: connectionId, schemaKey: schemaKey)).value ?? [:]
        return stored.mapValues { CGPoint(x: $0.x, y: $0.y) }
    }

    func save(_ positions: [String: CGPoint], connectionId: UUID, schemaKey: String) {
        let stored = positions.mapValues { CodablePoint(x: $0.x, y: $0.y) }
        try? defaults.write(stored, to: key(connectionId: connectionId, schemaKey: schemaKey))
    }

    func clear(connectionId: UUID, schemaKey: String) {
        defaults.removeValue(for: key(connectionId: connectionId, schemaKey: schemaKey))
    }
}

private struct CodablePoint: Codable {
    let x: Double
    let y: Double
}
