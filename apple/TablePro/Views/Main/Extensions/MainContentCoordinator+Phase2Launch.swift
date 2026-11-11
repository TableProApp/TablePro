//
//  MainContentCoordinator+Phase2Launch.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func launchPhase2AfterApply(
        tableName: String?,
        isEditable: Bool,
        tabId: UUID,
        trigger: TableLoadTrigger,
        needsMetadataFetch: Bool,
        schemaTask: Task<FetchedTableSchema, Error>?,
        claim: TabExecutionClaim
    ) {
        if isEditable, let tableName, trigger.countsRows {
            // Marked pending here: phase 1 clears `isLoading` first, so without it the tab looks settled and offers Count Exactly early.
            tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = true }
            launchPhase2(
                tableName: tableName,
                tabId: tabId,
                connectionType: connection.type,
                needsMetadataFetch: needsMetadataFetch,
                schemaTask: schemaTask
            )
        } else if isEditable, let tableName, needsMetadataFetch {
            // A tick keeps the count it has; only a manual Refresh recounts.
            launchPhase2Work(
                tableName: tableName,
                tabId: tabId,
                connectionType: connection.type,
                schemaTask: schemaTask,
                countsRows: false
            )
        } else if !isEditable || tableName == nil {
            clearChangesIfCurrent(claim: claim)
        }
    }
}
