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
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>
    ) {
        let originalValues = parent.changeManager.getOriginalValues()
        var deltas: [Delta] = []
        if let (tab, _) = parent.tabManager.selectedTabAndIndex {
            let tabId = tab.id
            let insertedIDs = collectInsertedRowIDs(
                tabId: tabId,
                indices: parent.changeManager.insertedRowIndices
            )
            let edits = originalValues.map { (row: $0.0, column: $0.1, value: $0.2) }
            if !edits.isEmpty {
                let editDelta = parent.mutateActiveTableRows(for: tabId) { rows in
                    rows.editMany(edits)
                }
                if editDelta != .none {
                    deltas.append(editDelta)
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

        if let tableName = parent.tabManager.selectedTab?.tableContext.tableName {
            parent.saveLastFilters(for: tableName)
        }

        pendingTruncates.removeAll()
        pendingDeletes.removeAll()
        parent.changeManager.clearChangesAndUndoHistory()

        if let (_, index) = parent.tabManager.selectedTabAndIndex {
            parent.tabManager.mutate(at: index) { $0.pendingChanges = TabChangeSnapshot() }
        }

        Task { [parent] in await parent.refreshTables() }
    }

    private func collectInsertedRowIDs(tabId: UUID, indices: Set<Int>) -> Set<RowID> {
        guard !indices.isEmpty else { return [] }
        guard let tableRows = parent.tabSessionRegistry.existingTableRows(for: tabId) else { return [] }
        var ids = Set<RowID>()
        for index in indices where index >= 0 && index < tableRows.rows.count {
            let id = tableRows.rows[index].id
            if id.isInserted {
                ids.insert(id)
            }
        }
        return ids
    }
}
