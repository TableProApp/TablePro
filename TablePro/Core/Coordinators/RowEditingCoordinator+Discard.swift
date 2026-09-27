//
//  RowEditingCoordinator+Discard.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

extension RowEditingCoordinator {
    // MARK: - Sidebar Transaction

    /// Edits made in the row inspector belong to the selected tab, so they run on that
    /// tab's database. The scope is read before the authorization prompt, which awaits a
    /// sheet and Touch ID and gives the selection time to move somewhere else.
    func executeSidebarChanges(statements: [ParameterizedStatement]) async throws {
        guard let scope = parent.selectedTabScope else {
            throw DatabaseError.notConnected
        }

        let sqlPreview = statements.map(\.sql).joined(separator: "\n")
        let kind = OperationKind.from(QueryClassifier.classifyTier(sqlPreview, databaseType: parent.connection.type))
        let decision = await ExecutionGateProvider.shared.authorize(
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
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await DataWriteExecutor.run(statements: statements, mode: mode, on: driver)
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

        Task { [parent] in await parent.refreshTables() }
    }

    /// Puts the loaded rows back the way the server last reported them.
    ///
    /// An edit is written straight into the tab's `TableRows` as well as being recorded, so
    /// clearing the change records alone leaves the edited values on screen with nothing tracking
    /// them, and the next edit captures an unsaved value as its baseline. A discard that re-queries
    /// replaces the buffer wholesale and needs none of this; one that does not has to undo it here.
    func restoreRowBufferToOriginals() {
        var deltas: [Delta] = []
        if let (tab, _) = parent.tabManager.selectedTabAndIndex,
           let tableRows = parent.tabSessionRegistry.existingTableRows(for: tab.id) {
            let tabId = tab.id
            let insertedIDs = parent.changeManager.insertedRowIDs
            var restoredCells: [(rowID: RowID, columnIndex: Int)] = []
            var absentCells: Set<CellPosition> = []
            let edits = parent.changeManager.getOriginalValues().compactMap { original in
                tableRows.index(of: original.rowID).map { storageRow -> (row: Int, column: Int, value: PluginCellValue) in
                    restoredCells.append((rowID: original.rowID, columnIndex: original.columnIndex))
                    if original.isAbsent {
                        absentCells.insert(CellPosition(row: storageRow, column: original.columnIndex))
                    }
                    return (row: storageRow, column: original.columnIndex, value: original.value)
                }
            }
            if !edits.isEmpty {
                let editDelta = parent.mutateActiveTableRows(for: tabId) { rows in
                    rows.editMany(edits, absentCells: absentCells)
                }
                /// `editMany` names the rows it changed by their position in storage, and the grid
                /// reads a delta's rows as display positions.
                if editDelta != .none {
                    deltas.append(restoredCellsDelta(restoredCells, in: tableRows))
                }
            }
            if !insertedIDs.isEmpty {
                let removeDelta = parent.mutateActiveTableRows(for: tabId) { rows in
                    rows.remove(rowIDs: insertedIDs)
                }
                if removeDelta != .none {
                    deltas.append(removeDelta)
                }
            }
        }

        for delta in deltas {
            parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(delta)
        }
        /// The row inspector reads its fields from the buffer this just rewrote, and nothing else
        /// in `InspectorTrigger` moves on a discard.
        parent.gridDisplayRevision &+= 1
    }

    private func restoredCellsDelta(
        _ cells: [(rowID: RowID, columnIndex: Int)],
        in tableRows: TableRows
    ) -> Delta {
        let displayIDs = parent.activeGridDisplayIDs
        var positions: Set<CellPosition> = []
        for cell in cells {
            guard let displayRow = DisplayRowMapping.displayIndex(
                forRowID: cell.rowID,
                displayIDs: displayIDs,
                in: tableRows
            ) else { continue }
            positions.insert(CellPosition(row: displayRow, column: cell.columnIndex))
        }
        return positions.isEmpty ? .none : .cellsChanged(positions)
    }
}
