import Foundation

enum TagFilterMode: String, Codable {
    case any
    case all
}

struct TagFilter: Equatable {
    var selectedIds: Set<UUID> = []
    var mode: TagFilterMode = .any

    var isActive: Bool { !selectedIds.isEmpty }

    func matches(_ connection: DatabaseConnection) -> Bool {
        guard isActive else { return true }
        let ids = Set(connection.tagIds)
        switch mode {
        case .any:
            return !selectedIds.isDisjoint(with: ids)
        case .all:
            return selectedIds.isSubset(of: ids)
        }
    }
}
