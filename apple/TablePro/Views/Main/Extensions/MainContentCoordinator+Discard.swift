//
//  MainContentCoordinator+Discard.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func executeSidebarChanges(steps: [DataWriteStep]) async throws {
        try await rowEditingCoordinator.executeSidebarChanges(steps: steps)
    }

    func handleDiscard(
        pendingTruncates: inout Set<DatabaseTreeTableRef>,
        pendingDeletes: inout Set<DatabaseTreeTableRef>
    ) {
        commitActiveGridEdit()
        rowEditingCoordinator.handleDiscard(
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes
        )
    }
}
