//
//  MainContentCoordinator+TabStatePersistence.swift
//  TablePro
//

import Foundation

/// The view-layer half of `SessionTabStatePersisting`. One coordinator is enough to ask, because
/// `saveAggregatedSync()` collects the tabs of every window on the connection, not just its own.
@MainActor
internal final class SessionTabStatePersister: SessionTabStatePersisting {
    internal func persistTabState(for connectionId: UUID) {
        MainContentCoordinator.allActiveCoordinators()
            .first { $0.connectionId == connectionId }?
            .persistence
            .saveAggregatedSync()
    }
}
