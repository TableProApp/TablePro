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
        let coordinators = MainContentCoordinator.allActiveCoordinators()
            .filter { $0.connectionId == connectionId }
        for coordinator in coordinators {
            coordinator.dataTabDelegate?.tableViewCoordinator?.flushPendingColumnLayoutPersistence()
        }
        coordinators.first?.persistence.saveAggregatedSync()
    }
}
