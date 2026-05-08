//
//  MainContentCoordinator+SaveChanges.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func saveChanges(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        rowEditingCoordinator.saveChanges(
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes,
            tableOperationOptions: &tableOperationOptions
        )
    }
}
