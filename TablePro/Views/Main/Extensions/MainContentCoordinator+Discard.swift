//
//  MainContentCoordinator+Discard.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func executeSidebarChanges(statements: [ParameterizedStatement]) async throws {
        try await rowEditingCoordinator.executeSidebarChanges(statements: statements)
    }

    func handleDiscard(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>
    ) {
        rowEditingCoordinator.handleDiscard(
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes
        )
    }
}
