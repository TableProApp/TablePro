import Foundation
import TableProSyncTransport

extension SyncCoordinator {
    // False until the project type and both membership fields are writable.
    func isProjectSyncWritable() -> Bool {
        schema.writesProjects
    }

    func syncBoundary(settings: SyncSettings) -> SyncBoundary {
        let storage = services.connectionStorage
        let connections = storage.loadConnections()
        // An owner this Mac cannot read sends its records only when its standing says it syncs.
        let unreadableNotSynced = storage.unreadableConnectionIds.filter { changeTracker.standing(ofConnection: $0) != .syncs }
        return SyncBoundary(
            settings: settings,
            connections: storage.lastLoadFailed ? nil : connections,
            ownersKeptOffSync: changeTracker.ownersKeptOffSync.union(unreadableNotSynced),
            writableTypes: schema.writableTypes
        )
    }

    func pruneTombstones(within boundary: SyncBoundary) {
        metadataStorage.pruneTombstones(olderThan: Self.tombstoneRetentionDays) { type, tombstone in
            boundary.includes(tombstone, of: type)
        }
    }

    private static let tombstoneRetentionDays = 30
}
