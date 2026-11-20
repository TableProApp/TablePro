import Foundation

@MainActor
final class ERDiagramPositionStorage {
    static let shared = ERDiagramPositionStorage()
    private let defaults = AppStorageEnvironment.shared.defaults

    private init() {}

    private func key(connectionId: UUID, schemaKey: String) -> JSONDefaultsKey<[String: CodablePoint]> {
        JSONDefaultsKey("com.TablePro.erDiagram.positions.\(connectionId.uuidString).\(schemaKey)")
    }

    func load(connectionId: UUID, schemaKey: String) -> [CatalogName: CGPoint] {
        let stored = defaults.read(key(connectionId: connectionId, schemaKey: schemaKey)).value ?? [:]
        var positions: [CatalogName: CGPoint] = [:]
        for (key, point) in stored {
            positions[CatalogName(exactKey: key) ?? CatalogName(key)] = CGPoint(x: point.x, y: point.y)
        }
        return positions
    }

    func save(_ positions: [CatalogName: CGPoint], connectionId: UUID, schemaKey: String) {
        var stored: [String: CodablePoint] = [:]
        for (name, point) in positions.sorted(by: { $0.key < $1.key }) {
            // A String key equates two table names a server keeps apart, so the second is stored by its bytes.
            let key = stored[name.text] == nil ? name.text : name.exactKey
            stored[key] = CodablePoint(x: point.x, y: point.y)
        }
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
