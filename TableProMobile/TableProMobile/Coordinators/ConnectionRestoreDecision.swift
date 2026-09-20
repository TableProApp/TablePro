import Foundation

/// What the scene does with the connection id `@SceneStorage` kept from the last run. `hold` keeps
/// the id and presents nothing, which is how a locked launch reaches Face ID before anything dials.
nonisolated enum ConnectionRestoreDecision: Hashable, Sendable {
    case nothing
    case hold
    case present(UUID)

    static func resolve(storedId: UUID?, isHeld: Bool) -> ConnectionRestoreDecision {
        guard let storedId else { return .nothing }
        guard !isHeld else { return .hold }
        return .present(storedId)
    }

    var presentedId: UUID? {
        guard case .present(let id) = self else { return nil }
        return id
    }
}
