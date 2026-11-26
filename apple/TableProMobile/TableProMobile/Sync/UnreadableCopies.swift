import Foundation
import TableProSyncTransport

// Records the library holds by id but cannot read, by kind, as their CloudKit record names name them.
struct UnreadableCopies: Equatable {
    var connections: Set<UUID> = []
    var groups: Set<UUID> = []
    var tags: Set<UUID> = []

    var isEmpty: Bool {
        connections.isEmpty && groups.isEmpty && tags.isEmpty
    }

    init(connections: Set<UUID> = [], groups: Set<UUID> = [], tags: Set<UUID> = []) {
        self.connections = connections
        self.groups = groups
        self.tags = tags
    }

    init(recordNames: Set<String>) {
        for name in recordNames {
            guard let parsed = SyncRecordType.parse(recordName: name), let id = UUID(uuidString: parsed.id) else { continue }
            switch parsed.type {
            case .connection: connections.insert(id)
            case .group: groups.insert(id)
            case .tag: tags.insert(id)
            default: continue
            }
        }
    }

    var recordNames: Set<String> {
        Set(connections.map { SyncRecordType.connection.recordName(for: $0.uuidString) })
            .union(groups.map { SyncRecordType.group.recordName(for: $0.uuidString) })
            .union(tags.map { SyncRecordType.tag.recordName(for: $0.uuidString) })
    }
}
