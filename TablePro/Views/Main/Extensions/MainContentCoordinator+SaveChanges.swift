//
//  MainContentCoordinator+SaveChanges.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func saveChanges(
        pendingTruncates: inout Set<DatabaseTreeTableRef>,
        pendingDeletes: inout Set<DatabaseTreeTableRef>,
        tableOperationOptions: inout [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        rowEditingCoordinator.saveChanges(
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes,
            tableOperationOptions: &tableOperationOptions
        )
    }
}
