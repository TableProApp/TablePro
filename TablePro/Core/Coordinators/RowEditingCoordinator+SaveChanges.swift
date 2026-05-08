//
//  RowEditingCoordinator+SaveChanges.swift
//  TablePro
//

import Foundation
import os
import SwiftUI

private let saveChangesLogger = Logger(subsystem: "com.TablePro", category: "RowEditingCoordinator")

extension RowEditingCoordinator {
    func saveChanges(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        guard !parent.safeModeLevel.blocksAllWrites else {
            if let index = parent.tabManager.selectedTabIndex {
                parent.tabManager.mutate(at: index) {
                    $0.execution.errorMessage = String(localized: "Cannot save changes: connection is read only")
                }
            }
            parent.saveCompletionContinuation?.resume(returning: false)
            parent.saveCompletionContinuation = nil
            return
        }

        let hasEditedCells = parent.changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else {
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
            return
        }

        let allStatements: [ParameterizedStatement]
        do {
            allStatements = try parent.assemblePendingStatements(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        } catch {
            if let index = parent.tabManager.selectedTabIndex {
                parent.tabManager.mutate(at: index) { $0.execution.errorMessage = error.localizedDescription }
            }
            parent.saveCompletionContinuation?.resume(returning: false)
            parent.saveCompletionContinuation = nil
            return
        }

        guard !allStatements.isEmpty else {
            if let index = parent.tabManager.selectedTabIndex {
                parent.tabManager.mutate(at: index) {
                    $0.execution.errorMessage = String(localized: "Could not generate SQL for changes.")
                }
            }
            parent.saveCompletionContinuation?.resume(returning: false)
            parent.saveCompletionContinuation = nil
            return
        }

        let level = parent.safeModeLevel
        if level.requiresConfirmation {
            let sqlPreview = allStatements.map(\.sql).joined(separator: "\n")
            let snapshotTruncates = pendingTruncates
            let snapshotDeletes = pendingDeletes
            let snapshotOptions = tableOperationOptions
            if hasPendingTableOps {
                pendingTruncates.removeAll()
                pendingDeletes.removeAll()
                for table in snapshotTruncates.union(snapshotDeletes) {
                    tableOperationOptions.removeValue(forKey: table)
                }
            }
            let connId = parent.connection.id
            Task { [weak self, parent] in
                guard let self else { return }
                let window = NSApp.keyWindow
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: true,
                    sql: sqlPreview,
                    operationDescription: String(localized: "Save Changes"),
                    window: window,
                    databaseType: parent.connection.type
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
                    if hasPendingTableOps {
                        DatabaseManager.shared.updateSession(connId) { session in
                            session.pendingTruncates = snapshotTruncates
                            session.pendingDeletes = snapshotDeletes
                            for (table, opts) in snapshotOptions {
                                session.tableOperationOptions[table] = opts
                            }
                        }
                    }
                    parent.saveCompletionContinuation?.resume(returning: false)
                    parent.saveCompletionContinuation = nil
                }
            }
            return
        }

        executeCommitStatements(
            allStatements,
            clearTableOps: hasPendingTableOps,
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes,
            tableOperationOptions: &tableOperationOptions
        )
    }

    private func executeCommitStatements(
        _ statements: [ParameterizedStatement],
        clearTableOps: Bool,
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        let validStatements = statements.filter { !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validStatements.isEmpty else {
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
            return
        }

        let deletedTables = Set(pendingDeletes)
        let truncatedTables = Set(pendingTruncates)
        let conn = parent.connection
        let dbType = parent.connection.type

        let fkWasDisabled = PluginManager.shared.supportsForeignKeyDisable(for: dbType)
            && deletedTables.union(truncatedTables).contains { tableName in
                tableOperationOptions[tableName]?.ignoreForeignKeys == true
            }

        var capturedOptions: [String: TableOperationOptions] = [:]
        for table in deletedTables.union(truncatedTables) {
            capturedOptions[table] = tableOperationOptions[table]
        }

        if clearTableOps {
            pendingTruncates.removeAll()
            pendingDeletes.removeAll()
            for table in deletedTables.union(truncatedTables) {
                tableOperationOptions.removeValue(forKey: table)
            }
        }

        Task { [weak self, parent] in
            guard let self else { return }
            let overallStartTime = Date()

            do {
                guard let driver = DatabaseManager.shared.driver(for: parent.connectionId) else {
                    if let index = parent.tabManager.selectedTabIndex {
                        parent.tabManager.mutate(at: index) {
                            $0.execution.errorMessage = String(localized: "Not connected to database")
                        }
                    }
                    throw DatabaseError.notConnected
                }

                let useTransaction = driver.supportsTransactions

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
                            databaseName: parent.activeDatabaseName,
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
                        do {
                            try await driver.rollbackTransaction()
                        } catch {
                            saveChangesLogger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    throw error
                }

                parent.changeManager.clearChangesAndUndoHistory()
                if let index = parent.tabManager.selectedTabIndex {
                    parent.tabManager.mutate(at: index) {
                        $0.pendingChanges = TabChangeSnapshot()
                        $0.execution.errorMessage = nil
                    }
                }

                if clearTableOps {
                    if !deletedTables.isEmpty {
                        let tabIdsToRemove = Set(
                            parent.tabManager.tabs
                                .filter { $0.tabType == .table && deletedTables.contains($0.tableContext.tableName ?? "") }
                                .map(\.id)
                        )

                        if !tabIdsToRemove.isEmpty {
                            let firstRemovedIndex = parent.tabManager.tabs
                                .firstIndex { tabIdsToRemove.contains($0.id) } ?? 0
                            for tabId in tabIdsToRemove {
                                parent.tabSessionRegistry.removeTableRows(for: tabId)
                            }
                            parent.tabManager.tabs.removeAll { tabIdsToRemove.contains($0.id) }
                            if !parent.tabManager.tabs.isEmpty {
                                let neighborIndex = min(firstRemovedIndex, parent.tabManager.tabs.count - 1)
                                parent.tabManager.selectedTabId = parent.tabManager.tabs[neighborIndex].id
                            } else {
                                parent.tabManager.selectedTabId = nil
                            }
                        }
                    }

                    Task { [parent] in await parent.refreshTables() }
                }

                if parent.tabManager.selectedTabIndex != nil && !parent.tabManager.tabs.isEmpty {
                    parent.runQuery()
                }

                parent.saveCompletionContinuation?.resume(returning: true)
                parent.saveCompletionContinuation = nil
            } catch {
                let executionTime = Date().timeIntervalSince(overallStartTime)

                if fkWasDisabled, let driver = DatabaseManager.shared.driver(for: parent.connectionId) {
                    for statement in parent.fkEnableStatements(for: dbType) {
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
                    databaseName: parent.activeDatabaseName,
                    executionTime: executionTime,
                    rowCount: 0,
                    wasSuccessful: false,
                    errorMessage: error.localizedDescription
                )

                if let index = parent.tabManager.selectedTabIndex {
                    parent.tabManager.mutate(at: index) {
                        $0.execution.errorMessage = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
                    }
                }

                AlertHelper.showErrorSheet(
                    title: String(localized: "Save Failed"),
                    message: error.localizedDescription,
                    window: parent.contentWindow
                )

                if clearTableOps {
                    DatabaseManager.shared.updateSession(conn.id) { session in
                        session.pendingTruncates = truncatedTables
                        session.pendingDeletes = deletedTables
                        for (table, opts) in capturedOptions {
                            session.tableOperationOptions[table] = opts
                        }
                    }
                }

                parent.saveCompletionContinuation?.resume(returning: false)
                parent.saveCompletionContinuation = nil
            }
        }
    }
}
