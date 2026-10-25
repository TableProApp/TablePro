//
//  MainContentCoordinator+TabStatePersistence.swift
//  TablePro
//

import Foundation

// One coordinator is enough to ask: saveAggregatedSync() collects the tabs of every window on the connection.
@MainActor
internal final class SessionTabStatePersister: SessionTabStatePersisting {
    internal func persistTabState(for connectionId: UUID) {
        let coordinators = MainContentCoordinator.allActiveCoordinators()
            .filter { $0.connectionId == connectionId }
        for coordinator in coordinators {
            coordinator.flushColumnLayoutPersistence()
        }
        coordinators.first?.persistence.saveAggregatedSync()
    }
}
