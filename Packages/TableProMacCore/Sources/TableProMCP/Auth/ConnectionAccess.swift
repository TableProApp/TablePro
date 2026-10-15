import Foundation

public enum ConnectionAccess: Sendable, Codable, Equatable {
    case all
    case limited(Set<UUID>)

    var allowedIds: Set<UUID>? {
        switch self {
        case .all: return nil
        case .limited(let ids): return ids
        }
    }

    public func allows(_ connectionId: UUID) -> Bool {
        switch self {
        case .all: return true
        case .limited(let ids): return ids.contains(connectionId)
        }
    }
}
