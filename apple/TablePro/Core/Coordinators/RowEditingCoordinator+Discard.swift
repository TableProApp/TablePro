//
//  RowEditingCoordinator+Discard.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

extension RowEditingCoordinator {
    // MARK: - Sidebar Transaction

    // Scope is read before the authorization prompt (sheet and Touch ID), which gives the selection time to move.
    func executeSidebarChanges(steps: [DataWriteStep]) async throws {
        guard let scope = parent.selectedTabScope else {
            throw DatabaseError.notConnected
        }

        let sqlPreview = steps.map(\.statement.sql).joined(separator: "\n")
        let kind = OperationKind.from(QueryClassifier.classifyTier(sqlPreview, databaseType: parent.connection.type))
        let decision = await parent.executionGate.authorize(
            OperationRequest(
                connectionId: parent.connectionId,
                databaseType: parent.connection.type,
                sql: sqlPreview,
                kind: kind,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Save Sidebar Changes")
            )
        )
        guard case .authorized = decision else {
            throw DatabaseError.queryFailed(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        let mode: PluginTransactionAccessMode = kind.declaresWrite ? .readWrite : .serverDefault
        let plan = DataWritePlan(scope: scope, databaseType: parent.connection.type, steps: steps)
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await DataWriteExecutor.run(plan, mode: mode, on: driver)
        }
    }

    // MARK: - Discard

    func handleDiscard(
        pendingTruncates: inout Set<DatabaseTreeTableRef>,
        pendingDeletes: inout Set<DatabaseTreeTableRef>
    ) {
        restoreRowBufferToOriginals()

        if let tab = parent.tabManager.selectedTab {
            parent.saveLastFilters(of: tab)
        }

        pendingTruncates.removeAll()
        pendingDeletes.removeAll()
        parent.changeManager.clearChangesAndUndoHistory()

        if let (_, index) = parent.tabManager.selectedTabAndIndex {
            parent.tabManager.mutate(at: index) { $0.pendingChanges = TabChangeSnapshot() }
        }
        parent.resumeDeferredTableRefresh()
    }

    // Edits are written into the loaded rows too; a discard that does not re-query must undo them here or they stay untracked.
    func restoreRowBufferToOriginals() {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex,
              let tableRows = parent.tabSessionRegistry.existingTableRows(for: tab.id) else {
            parent.gridDisplayRevision &+= 1
            return
        }
        let tabId = tab.id
        let insertedIDs = parent.changeManager.insertedRowIDs
        var absentCells: Set<CellPosition> = []
        let edits = parent.changeManager.getOriginalValues().compactMap { original in
            tableRows.index(of: original.rowID).map { storageRow -> (row: Int, column: Int, value: PluginCellValue) in
                if original.isAbsent {
                    absentCells.insert(CellPosition(row: storageRow, column: original.columnIndex))
                }
                return (row: storageRow, column: original.columnIndex, value: original.value)
            }
        }
        if !edits.isEmpty {
            parent.mutateActiveTableRows(for: tabId) { rows in rows.editMany(edits, absentCells: absentCells) }
        }
        if !insertedIDs.isEmpty {
            parent.mutateActiveTableRows(for: tabId) { rows in rows.remove(rowIDs: insertedIDs) }
        }
        // The inspector reads its fields from the rows this rewrote, and nothing else it watches moves on a discard.
        parent.gridDisplayRevision &+= 1
    }
}
