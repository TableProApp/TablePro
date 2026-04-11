//
//  MainContentCoordinator+SaveChanges.swift
//  TablePro
//

import Foundation
import os
import SwiftUI

private let saveChangesLogger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")

extension MainContentCoordinator {
    // MARK: - Save Changes

    func saveChanges(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        guard !safeModeLevel.blocksAllWrites else {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = "Cannot save changes: connection is read-only"
            }
            saveCompletionContinuation?.resume(returning: false)
            saveCompletionContinuation = nil
            return
        }

        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else {
            saveCompletionContinuation?.resume(returning: true)
            saveCompletionContinuation = nil
            return
        }

        let allStatements: [ParameterizedStatement]
        do {
            allStatements = try assemblePendingStatements(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        } catch {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = error.localizedDescription
            }
            saveCompletionContinuation?.resume(returning: false)
            saveCompletionContinuation = nil
            return
        }

        guard !allStatements.isEmpty else {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = "Could not generate SQL for changes."
            }
            saveCompletionContinuation?.resume(returning: false)
            saveCompletionContinuation = nil
            return
        }

        let level = safeModeLevel
        if level.requiresConfirmation {
            let sqlPreview = allStatements.map(\.sql).joined(separator: "\n")
            // Snapshot inout values before clearing — needed for executeCommitStatements
            let snapshotTruncates = pendingTruncates
            let snapshotDeletes = pendingDeletes
            let snapshotOptions = tableOperationOptions
            // Clear pending ops immediately so caller's bindings update the session.
            // On cancel: restored via DatabaseManager.updateSession.
            // On execution failure: restored by executeCommitStatements' existing restore logic.
            if hasPendingTableOps {
                pendingTruncates.removeAll()
                pendingDeletes.removeAll()
                for table in snapshotTruncates.union(snapshotDeletes) {
                    tableOperationOptions.removeValue(forKey: table)
                }
            }
            let connId = connection.id
            Task { @MainActor in
                let window = NSApp.keyWindow
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: true,
                    sql: sqlPreview,
                    operationDescription: String(localized: "Save Changes"),
                    window: window,
                    databaseType: connection.type
                )
                switch permission {
                case .allowed:
                    var truncs = snapshotTruncates
                    var dels = snapshotDeletes
                    var opts = snapshotOptions
                    executeCommitStatements(
                        allStatements,
                        clearTableOps: hasPendingTableOps,
                        pendingTruncates: &truncs,
                        pendingDeletes: &dels,
                        tableOperationOptions: &opts
                    )
                case .blocked:
                    // Restore pending ops since user cancelled
                    if hasPendingTableOps {
                        DatabaseManager.shared.updateSession(connId) { session in
                            session.pendingTruncates = snapshotTruncates
                            session.pendingDeletes = snapshotDeletes
                            for (table, opts) in snapshotOptions {
                                session.tableOperationOptions[table] = opts
                            }
                        }
                    }
                    saveCompletionContinuation?.resume(returning: false)
                    saveCompletionContinuation = nil
                }
            }
            return
        }

        // Pass statements as array to avoid SQL injection via semicolon splitting
        executeCommitStatements(
            allStatements,
            clearTableOps: hasPendingTableOps,
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes,
            tableOperationOptions: &tableOperationOptions
        )
    }

    /// Executes an array of SQL statements sequentially.
    /// This approach prevents SQL injection by avoiding semicolon-based string splitting.
    /// - Parameters:
    ///   - statements: Pre-segmented array of SQL statements to execute
    ///   - clearTableOps: Whether to clear pending table operations on success
    ///   - pendingTruncates: Inout binding to pending truncate operations (restored on failure)
    ///   - pendingDeletes: Inout binding to pending delete operations (restored on failure)
    ///   - tableOperationOptions: Inout binding to operation options (restored on failure)
    private func executeCommitStatements(
        _ statements: [ParameterizedStatement],
        clearTableOps: Bool,
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        let validStatements = statements.filter { !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validStatements.isEmpty else {
            saveCompletionContinuation?.resume(returning: true)
            saveCompletionContinuation = nil
            return
        }

        let deletedTables = Set(pendingDeletes)
        let truncatedTables = Set(pendingTruncates)
        let conn = connection
        let dbType = connection.type

        // Track if FK checks were disabled (need to re-enable on failure)
        let fkWasDisabled = PluginManager.shared.supportsForeignKeyDisable(for: dbType) && deletedTables.union(truncatedTables).contains { tableName in
            tableOperationOptions[tableName]?.ignoreForeignKeys == true
        }

        // Capture options before clearing (for potential restore on failure)
        var capturedOptions: [String: TableOperationOptions] = [:]
        for table in deletedTables.union(truncatedTables) {
            capturedOptions[table] = tableOperationOptions[table]
        }

        // Clear operations immediately (to prevent double-execution)
        // Store references to restore synchronously on failure
        if clearTableOps {
            pendingTruncates.removeAll()
            pendingDeletes.removeAll()
            for table in deletedTables.union(truncatedTables) {
                tableOperationOptions.removeValue(forKey: table)
            }
        }

        Task { @MainActor in
            let overallStartTime = Date()

            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = "Not connected to database"
                    }
                    throw DatabaseError.notConnected
                }

                // Redis MULTI/EXEC is not a true transaction (no rollback on failure),
                // so execute statements individually without wrapping.
                let useTransaction = dbType != .redis

                if useTransaction {
                    try await driver.beginTransaction()
                }

                do {
                    for statement in validStatements {
                        let statementStartTime = Date()
                        if statement.parameters.isEmpty {
                            _ = try await driver.execute(query: statement.sql)
                        } else {
                            _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
                        }

                        let executionTime = Date().timeIntervalSince(statementStartTime)

                        let historySQL = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                        QueryHistoryManager.shared.recordQuery(
                            query: historySQL.hasSuffix(";") ? historySQL : historySQL + ";",
                            connectionId: conn.id,
                            databaseName: conn.database,
                            executionTime: executionTime,
                            rowCount: 0,
                            wasSuccessful: true,
                            errorMessage: nil
                        )
                    }

                    if useTransaction {
                        try await driver.commitTransaction()
                    }
                } catch {
                    if useTransaction {
                        try? await driver.rollbackTransaction()
                    }
                    throw error
                }

                changeManager.clearChangesAndUndoHistory()
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].pendingChanges = TabPendingChanges()
                    tabManager.tabs[index].errorMessage = nil
                }

                if clearTableOps {
                    // Remove tabs for deleted tables
                    if !deletedTables.isEmpty {
                        let tabIdsToRemove = Set(
                            tabManager.tabs
                                .filter { $0.tabType == .table && deletedTables.contains($0.tableName ?? "") }
                                .map(\.id)
                        )

                        if !tabIdsToRemove.isEmpty {
                            let firstRemovedIndex = tabManager.tabs
                                .firstIndex { tabIdsToRemove.contains($0.id) } ?? 0
                            tabManager.tabs.removeAll { tabIdsToRemove.contains($0.id) }
                            if !tabManager.tabs.isEmpty {
                                let neighborIndex = min(firstRemovedIndex, tabManager.tabs.count - 1)
                                tabManager.selectedTabId = tabManager.tabs[neighborIndex].id
                            } else {
                                tabManager.selectedTabId = nil
                            }
                        }
                    }

                    Task { await self.refreshTables() }
                }

                if tabManager.selectedTabIndex != nil && !tabManager.tabs.isEmpty {
                    runQuery()
                }

                saveCompletionContinuation?.resume(returning: true)
                saveCompletionContinuation = nil
            } catch {
                let executionTime = Date().timeIntervalSince(overallStartTime)

                // Try to re-enable FK checks if they were disabled
                if fkWasDisabled, let driver = DatabaseManager.shared.driver(for: connectionId) {
                    for statement in self.fkEnableStatements(for: dbType) {
                        do {
                            _ = try await driver.execute(query: statement)
                        } catch {
                            saveChangesLogger.warning("Failed to re-enable foreign key checks with statement '\(statement, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }

                let allSQL = validStatements.map { $0.sql }.joined(separator: "; ")
                QueryHistoryManager.shared.recordQuery(
                    query: allSQL,
                    connectionId: conn.id,
                    databaseName: conn.database,
                    executionTime: executionTime,
                    rowCount: 0,
                    wasSuccessful: false,
                    errorMessage: error.localizedDescription
                )

                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].errorMessage = "Save failed: \(error.localizedDescription)"
                }

                // Show error alert to user
                AlertHelper.showErrorSheet(
                    title: String(localized: "Save Failed"),
                    message: error.localizedDescription,
                    window: contentWindow
                )

                // Restore operations on failure so user can retry
                if clearTableOps {
                    DatabaseManager.shared.updateSession(conn.id) { session in
                        session.pendingTruncates = truncatedTables
                        session.pendingDeletes = deletedTables
                        for (table, opts) in capturedOptions {
                            session.tableOperationOptions[table] = opts
                        }
                    }
                }

                saveCompletionContinuation?.resume(returning: false)
                saveCompletionContinuation = nil
            }
        }
    }
}
