//
//  RowEditingCoordinator+Discard.swift
//  TablePro
//

import AppKit
import Foundation
import os

private let discardLogger = Logger(subsystem: "com.TablePro", category: "RowEditingCoordinator+Discard")

extension RowEditingCoordinator {
    // MARK: - Sidebar Transaction

    func executeSidebarChanges(statements: [ParameterizedStatement]) async throws {
        let sqlPreview = statements.map(\.sql).joined(separator: "\n")
        let window = await MainActor.run { NSApp.keyWindow }
        let permission = await SafeModeGuard.checkPermission(
            level: parent.safeModeLevel,
            isWriteOperation: true,
            sql: sqlPreview,
            operationDescription: String(localized: "Save Sidebar Changes"),
            window: window,
            databaseType: parent.connection.type
        )
        if case .blocked = permission {
            return
        }

        guard let driver = DatabaseManager.shared.driver(for: parent.connectionId) else {
            throw DatabaseError.notConnected
        }

        let useTransaction = driver.supportsTransactions

        if useTransaction {
            try await driver.beginTransaction()
        }

        do {
            for stmt in statements {
                if stmt.parameters.isEmpty {
                    _ = try await driver.execute(query: stmt.sql)
                } else {
                    _ = try await driver.executeParameterized(query: stmt.sql, parameters: stmt.parameters)
                }
            }
            if useTransaction {
                try await driver.commitTransaction()
            }
        } catch {
            if useTransaction {
                do {
                    try await driver.rollbackTransaction()
                } catch {
                    discardLogger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
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
