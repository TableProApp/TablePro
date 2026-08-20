//
//  RowEditingCoordinator+SaveChanges.swift
//  TablePro
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

private let saveChangesLogger = Logger(subsystem: "com.TablePro", category: "RowEditingCoordinator")

extension RowEditingCoordinator {
    /// The scope is read once, before the destructive-delete sheet and the authorization
    /// prompt, so moving the selection to another database while either is open cannot
    /// retarget the statements that were generated for the edited tab.
    func saveChanges(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        let hasEditedCells = parent.changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else {
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
            return
        }

        guard let scope = parent.selectedTabScope else {
            failSave(message: String(localized: "Not connected to database"))
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
            failSave(message: error.localizedDescription)
            return
        }

        guard !allStatements.isEmpty else {
            failSave(message: String(localized: "Could not generate SQL for changes."))
            return
        }

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
        let kind: OperationKind = hasPendingTableOps ? .destructiveQuery : .writeQuery
        let deleteConfirmation = BulkDeleteConfirmation(deletedRowCount: parent.changeManager.deletedRowIndices.count)
        Task { [weak self, parent] in
            guard let self else { return }

            if deleteConfirmation.isRequired {
                let confirmed = await AlertHelper.confirmDestructive(
                    title: deleteConfirmation.title,
                    message: deleteConfirmation.message,
                    confirmButton: deleteConfirmation.confirmButtonTitle,
                    window: parent.contentWindow
                )
                guard confirmed else {
                    if hasPendingTableOps {
                        restorePendingTableOperations(
                            connectionId: connId,
                            truncates: snapshotTruncates,
                            deletes: snapshotDeletes,
                            options: snapshotOptions
                        )
                    }
                    parent.saveCompletionContinuation?.resume(returning: false)
                    parent.saveCompletionContinuation = nil
                    return
                }
            }

            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connId,
                    databaseType: parent.connection.type,
                    sql: sqlPreview,
                    kind: kind,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(localized: "Save Changes")
                )
            )
            switch decision {
            case .authorized:
                var truncs = snapshotTruncates
                var dels = snapshotDeletes
                var opts = snapshotOptions
                executeCommitStatements(
                    allStatements,
                    scope: scope,
                    clearTableOps: hasPendingTableOps,
                    pendingTruncates: &truncs,
                    pendingDeletes: &dels,
                    tableOperationOptions: &opts
                )
            case .denied(let reason):
                if hasPendingTableOps {
                    restorePendingTableOperations(
                        connectionId: connId,
                        truncates: snapshotTruncates,
                        deletes: snapshotDeletes,
                        options: snapshotOptions
                    )
                }
                failSave(message: reason)
            }
        }
    }

    /// Every statement, the rollback and the foreign-key re-enable run inside one
    /// `withScopedDriver` lease, so they all reach the same handle on the tab's own
    /// database. Everything else stays outside it: the connection's driver gate is not
    /// reentrant, so refreshing or re-running a query from inside the body would deadlock.
    private func executeCommitStatements(
        _ statements: [ParameterizedStatement],
        scope: DatabaseScope,
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
        let foreignKeyEnableStatements = fkWasDisabled ? parent.fkEnableStatements(for: dbType) : []

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

        let route = DatabaseManager.shared.executionRoute(for: scope)

        Task { [weak self, parent] in
            guard let self else { return }
            let overallStartTime = Date()

            do {
                let executionTimes = try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: route,
                    cancellation: .protectedWrite
                ) { driver in
                    try await Self.runStatementsInTransaction(
                        validStatements,
                        mode: .readWrite,
                        foreignKeyEnableStatements: foreignKeyEnableStatements,
                        on: driver
                    )
                }

                for (statement, executionTime) in zip(validStatements, executionTimes) {
                    let historySQL = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                    parent.recordHistory(
                        QueryHistoryRecordRequest(
                            query: historySQL.hasSuffix(";") ? historySQL : historySQL + ";",
                            connectionId: conn.id,
                            databaseName: scope.database,
                            databaseType: conn.type,
                            schemaName: scope.schema,
                            source: .rowEdit,
                            executionTime: executionTime,
                            rowCount: -1,
                            wasSuccessful: true
                        )
                    )
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

                for statement in validStatements {
                    let historySQL = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                    parent.recordHistory(
                        QueryHistoryRecordRequest(
                            query: historySQL.hasSuffix(";") ? historySQL : historySQL + ";",
                            connectionId: conn.id,
                            databaseName: scope.database,
                            databaseType: conn.type,
                            schemaName: scope.schema,
                            source: .rowEdit,
                            executionTime: executionTime,
                            rowCount: -1,
                            wasSuccessful: false,
                            errorMessage: error.localizedDescription
                        )
                    )
                }

                let diagnosis = DatabaseWriteRejectionDiagnosis.classify(error)

                AlertHelper.showErrorSheet(
                    title: String(localized: "Save Failed"),
                    message: diagnosis?.errorDescription ?? error.localizedDescription,
                    recoverySuggestion: diagnosis?.recoverySuggestion,
                    window: parent.contentWindow
                )

                if clearTableOps {
                    restorePendingTableOperations(
                        connectionId: conn.id,
                        truncates: truncatedTables,
                        deletes: deletedTables,
                        options: capturedOptions
                    )
                }

                failSave(
                    message: String(
                        format: String(localized: "Save failed: %@"),
                        DatabaseWriteRejectionDiagnosis.formatted(error)
                    )
                )
            }
        }
    }

    /// The rollback and the foreign-key re-enable are part of the same lease as the
    /// statements: resolving a driver again afterwards can reach a handle that has
    /// already been released, or one sitting on another database.
    nonisolated static func runStatementsInTransaction(
        _ statements: [ParameterizedStatement],
        mode: PluginTransactionAccessMode,
        foreignKeyEnableStatements: [String] = [],
        on driver: DatabaseDriver
    ) async throws -> [TimeInterval] {
        let useTransaction = driver.supportsTransactions
        if useTransaction {
            try await driver.beginTransaction(mode: mode)
        }

        var executionTimes: [TimeInterval] = []
        do {
            for statement in statements {
                let statementStartTime = Date()
                if statement.parameters.isEmpty {
                    _ = try await driver.execute(query: statement.sql)
                } else {
                    _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
                }
                executionTimes.append(Date().timeIntervalSince(statementStartTime))
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
            for statement in foreignKeyEnableStatements {
                do {
                    _ = try await driver.execute(query: statement)
                } catch {
                    saveChangesLogger.warning("Failed to re-enable foreign key checks with statement '\(statement, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
        return executionTimes
    }

    private func failSave(message: String) {
        if let index = parent.tabManager.selectedTabIndex {
            parent.tabManager.mutate(at: index) { $0.execution.errorMessage = message }
        }
        parent.saveCompletionContinuation?.resume(returning: false)
        parent.saveCompletionContinuation = nil
    }

    private func restorePendingTableOperations(
        connectionId: UUID,
        truncates: Set<String>,
        deletes: Set<String>,
        options: [String: TableOperationOptions]
    ) {
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.pendingTruncates = truncates
            session.pendingDeletes = deletes
            for (table, opts) in options {
                session.tableOperationOptions[table] = opts
            }
        }
    }
}
