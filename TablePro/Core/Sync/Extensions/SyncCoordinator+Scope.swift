import Foundation
import TableProSyncTransport

extension SyncCoordinator {
    func syncBoundary(settings: SyncSettings) -> SyncBoundary {
        let storage = services.connectionStorage
        let connections = storage.loadConnections()
        return SyncBoundary(
            settings: settings,
            connections: storage.lastLoadFailed ? nil : connections,
            ownersKeptOffSync: changeTracker.ownersKeptOffSync
        )
    }

    func pruneTombstones(within boundary: SyncBoundary) {
        metadataStorage.pruneTombstones(olderThan: Self.tombstoneRetentionDays) { type, tombstone in
            boundary.includes(tombstone, of: type)
        }
    }

    private static let tombstoneRetentionDays = 30
}
