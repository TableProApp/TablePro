//
//  MainContentCoordinator+Discard.swift
//  TablePro
//
//  Sidebar transaction execution and discard handling.
//

import AppKit
import Foundation
import os

private let discardLogger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator+Discard")

extension MainContentCoordinator {
    // MARK: - Table Creation

    /// Execute sidebar changes immediately (single transaction)
    /// Respects safe mode levels that require confirmation for write operations.
    func executeSidebarChanges(statements: [ParameterizedStatement]) async throws {
        let sqlPreview = statements.map(\.sql).joined(separator: "\n")
        let window = await MainActor.run { NSApp.keyWindow }
        let permission = await SafeModeGuard.checkPermission(
            level: safeModeLevel,
            isWriteOperation: true,
            sql: sqlPreview,
            operationDescription: String(localized: "Save Sidebar Changes"),
            window: window,
            databaseType: connection.type
        )
        if case .blocked = permission {
            return
        }

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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

    // MARK: - Discard Handling

    func handleDiscard(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>
    ) {
        let originalValues = changeManager.getOriginalValues()
        var deltas: [Delta] = []
        if let (tab, _) = tabManager.selectedTabAndIndex {
            let tabId = tab.id
            let insertedIDs = collectInsertedRowIDs(
                tabId: tabId,
                indices: changeManager.insertedRowIndices
            )
            let edits = originalValues.map { (row: $0.0, column: $0.1, value: $0.2) }
            if !edits.isEmpty {
                let editDelta = mutateActiveTableRows(for: tabId) { rows in
                    rows.editMany(edits)
                }
                if editDelta != .none {
                    deltas.append(editDelta)
                }
            }
            if !insertedIDs.isEmpty {
                let removeDelta = mutateActiveTableRows(for: tabId) { rows in
                    rows.remove(rowIDs: insertedIDs)
                }
                if removeDelta != .none {
                    deltas.append(removeDelta)
                }
            }
        }

        for delta in deltas {
            dataTabDelegate?.tableViewCoordinator?.applyDelta(delta)
        }

        if let tableName = tabManager.selectedTab?.tableContext.tableName {
            saveLastFilters(for: tableName)
        }

        pendingTruncates.removeAll()
        pendingDeletes.removeAll()
        changeManager.clearChangesAndUndoHistory()

        if let (_, index) = tabManager.selectedTabAndIndex {
            tabManager.tabs[index].pendingChanges = TabChangeSnapshot()
        }

        Task { await refreshTables() }
    }

    private func collectInsertedRowIDs(tabId: UUID, indices: Set<Int>) -> Set<RowID> {
        guard !indices.isEmpty else { return [] }
        guard let tableRows = tabSessionRegistry.existingTableRows(for: tabId) else { return [] }
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
