//
//  MainContentCoordinator+Discard.swift
//  TablePro
//
//  Sidebar transaction execution and discard handling.
//

import AppKit
import Foundation

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

        try await driver.beginTransaction()

        do {
            for stmt in statements {
                if stmt.parameters.isEmpty {
                    _ = try await driver.execute(query: stmt.sql)
                } else {
                    _ = try await driver.executeParameterized(query: stmt.sql, parameters: stmt.parameters)
                }
            }
            try await driver.commitTransaction()
        } catch {
            try? await driver.rollbackTransaction()
            throw error
        }
    }

    // MARK: - Discard Handling

    func handleDiscard(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>
    ) {
        let originalValues = changeManager.getOriginalValues()
        if let index = tabManager.selectedTabIndex {
            for (rowIndex, columnIndex, originalValue) in originalValues {
                if rowIndex < tabManager.tabs[index].resultRows.count,
                   columnIndex < tabManager.tabs[index].resultRows[rowIndex].count {
                    tabManager.tabs[index].resultRows[rowIndex][columnIndex] = originalValue
                }
            }

            let insertedIndices = changeManager.insertedRowIndices.sorted(by: >)
            for rowIndex in insertedIndices {
                if rowIndex < tabManager.tabs[index].resultRows.count {
                    tabManager.tabs[index].resultRows.remove(at: rowIndex)
                }
            }
        }

        pendingTruncates.removeAll()
        pendingDeletes.removeAll()
        changeManager.clearChangesAndUndoHistory()

        if let index = tabManager.selectedTabIndex {
            tabManager.tabs[index].pendingChanges = TabPendingChanges()
        }

        Task { await refreshTables() }
    }
}
