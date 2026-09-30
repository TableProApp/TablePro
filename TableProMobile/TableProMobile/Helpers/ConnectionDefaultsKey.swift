import Foundation

nonisolated enum ConnectionDefaultsKey: String, CaseIterable {
    case lastTab
    case lastDB
    case lastSchema
    case lastQuery

    func name(for connectionId: UUID) -> String {
        "\(rawValue).\(connectionId.uuidString)"
    }
}
