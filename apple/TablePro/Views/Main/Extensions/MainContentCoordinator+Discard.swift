//
//  MainContentCoordinator+Discard.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func executeSidebarChanges(steps: [DataWriteStep], viewTarget: PluginViewWriteTarget?) async throws {
        try await rowEditingCoordinator.executeSidebarChanges(steps: steps, viewTarget: viewTarget)
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
