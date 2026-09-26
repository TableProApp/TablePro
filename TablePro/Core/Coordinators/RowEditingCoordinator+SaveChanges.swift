//
//  RowEditingCoordinator+SaveChanges.swift
//  TablePro
//

import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit

private let saveChangesLogger = Logger(subsystem: "com.TablePro", category: "RowEditingCoordinator")

extension RowEditingCoordinator {
    /// The plan carries the scope it was built for, so it runs where its statements were
    /// generated however long the destructive-delete sheet and the authorization prompt stay
    /// open. Reading the selected tab's scope again at execution time is what let a queued drop
    /// land in whichever database the tab in front had moved to.
    func saveChanges(
        pendingTruncates: inout Set<DatabaseTreeTableRef>,
        pendingDeletes: inout Set<DatabaseTreeTableRef>,
        tableOperationOptions: inout [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        endInspectorEditRun()
        let hasEditedCells = parent.changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else {
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
            return
        }

        /// One change manager serves the whole window, so a second save cannot start while one is
        /// in flight. Say so: over the slow link this guard exists for, a Save that silently does
        /// nothing is indistinguishable from a Save that is broken.
        guard beginSaveInFlight() else {
            saveChangesLogger.debug("Save already in flight, refusing the repeat")
            if let index = parent.tabManager.selectedTabIndex {
                parent.tabManager.mutate(at: index) {
                    $0.execution.errorMessage = String(localized: "A save is already running in this window.")
                }
            }
            parent.saveCompletionContinuation?.resume(returning: false)
            parent.saveCompletionContinuation = nil
            return
        }

        guard parent.selectedTabScope != nil else {
            failSave(message: String(localized: "Not connected to database"))
            return
        }

        let plan: DataWritePlan
        do {
            plan = try parent.buildDataWritePlan(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        } catch {
            failSave(message: error.localizedDescription)
            return
        }

        guard !plan.isEmpty else {
            failSave(message: String(localized: "Could not generate SQL for changes."))
            return
        }

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
        let deleteConfirmation = BulkDeleteConfirmation(deletedRowCount: parent.changeManager.deletedRowIDs.count)
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
                    endSaveInFlight()
                    parent.saveCompletionContinuation?.resume(returning: false)
                    parent.saveCompletionContinuation = nil
                    return
                }
            }

            /// The gate and the confirmation alert show the plan with its values written in.
            /// Approving `UPDATE "users" SET "email" = ? WHERE "id" = ?` is approving nothing:
            /// it names no row and no value.
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connId,
                    databaseType: parent.connection.type,
                    sql: plan.displaySQL,
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
                executeCommitPlan(
                    plan,
                    scope: plan.scope,
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
    private func executeCommitPlan(
        _ plan: DataWritePlan,
        scope: DatabaseScope,
        clearTableOps: Bool,
        pendingTruncates: inout Set<DatabaseTreeTableRef>,
        pendingDeletes: inout Set<DatabaseTreeTableRef>,
        tableOperationOptions: inout [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        let validSteps = plan.steps.filter { !$0.statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validSteps.isEmpty else {
            endSaveInFlight()
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
            return
        }

        let deletedTables = Set(pendingDeletes)
        let truncatedTables = Set(pendingTruncates)
        let conn = parent.connection

        var capturedOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
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
        let savingTabId = parent.tabManager.selectedTabId

        Task { [weak self, parent] in
            guard let self else { return }
            let overallStartTime = Date()
            let operationStart = ContinuousClock.Instant.now

            do {
                let run = try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: route,
                    cancellation: .protectedWrite
                ) { driver in
                    try await DataWriteExecutor.run(plan, mode: .readWrite, on: driver)
                }

                let history = recordSuccessHistory(
                    steps: validSteps, results: run.results, connection: conn, scope: scope
                )
                recordSideStatementHistory(run.sideStatements, connection: conn, scope: scope)
                captureRewindRecord(plan: plan, history: history, connection: conn)

                finishSuccessfulSave(
                    plan: plan,
                    savingTabId: savingTabId,
                    clearTableOps: clearTableOps,
                    deletedTables: deletedTables,
                    truncatedTables: truncatedTables
                )

                endSaveInFlight()
                parent.saveCompletionContinuation?.resume(returning: true)
                parent.saveCompletionContinuation = nil
                reportSaveFinished(
                    .succeeded(OperationSummary(rowsAffected: run.results.reduce(0) { $0 + $1.rowsAffected })),
                    connection: conn,
                    database: scope.database,
                    tabId: savingTabId,
                    startedAt: operationStart
                )
            } catch {
                let executionTime = Date().timeIntervalSince(overallStartTime)
                reportSaveFinished(
                    .failed(reason: error.localizedDescription),
                    connection: conn,
                    database: scope.database,
                    tabId: savingTabId,
                    startedAt: operationStart
                )

                let partial = error as? DataWritePartialCommitError
                recordFailureHistory(
                    steps: validSteps,
                    committed: partial?.committed ?? [],
                    connection: conn,
                    scope: scope,
                    executionTime: executionTime,
                    error: error
                )

                let diagnosis = DatabaseWriteRejectionDiagnosis.classify(error)
                let writeError = error as? DataWriteError

                if let partial {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Save Incomplete"),
                        message: [partial.errorDescription, partial.partialCommitMessage]
                            .compactMap { $0 }.joined(separator: "\n\n"),
                        recoverySuggestion: partial.recoverySuggestion,
                        window: parent.contentWindow
                    )
                } else {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Save Failed"),
                        message: writeError?.errorDescription ?? diagnosis?.errorDescription
                            ?? error.localizedDescription,
                        recoverySuggestion: writeError?.recoverySuggestion ?? diagnosis?.recoverySuggestion,
                        window: parent.contentWindow
                    )
                }

                if clearTableOps {
                    /// On an engine whose DDL commits as it runs, a TRUNCATE before the failure has
                    /// already emptied its table, and nothing reports which ones ran. Queuing them
                    /// again would empty the table a second time on the next Save, rows added since
                    /// included, so they are left for the user to stage again.
                    let ddlRolledBack = DatabaseManager.shared.driver(for: conn.id)?.supportsTransactionalDDL ?? false
                    restorePendingTableOperations(
                        connectionId: conn.id,
                        truncates: ddlRolledBack ? truncatedTables : [],
                        deletes: deletedTables,
                        options: capturedOptions
                    )
                    reconcileDropsAfterFailedSave(deletedTables, scope: scope)
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

    /// The tab that started the save owns the outcome of it.
    ///
    /// One `changeManager` serves the whole window and swaps contents on every tab switch, so
    /// writing the completion into whichever tab is selected when the write lands clears the edits
    /// of a tab that had nothing to do with it, and re-runs that tab's query.
    private func finishSuccessfulSave(
        plan: DataWritePlan,
        savingTabId: UUID?,
        clearTableOps: Bool,
        deletedTables: Set<DatabaseTreeTableRef>,
        truncatedTables: Set<DatabaseTreeTableRef>
    ) {
        let savingTabIsSelected = savingTabId != nil && parent.tabManager.selectedTabId == savingTabId
        if savingTabIsSelected {
            parent.changeManager.clearChangesAndUndoHistory()
        }
        if let savingTabId, let index = parent.tabManager.tabs.firstIndex(where: { $0.id == savingTabId }) {
            parent.tabManager.mutate(at: index) {
                $0.pendingChanges = TabChangeSnapshot()
                $0.execution.errorMessage = nil
            }
        }

        if clearTableOps, !deletedTables.isEmpty {
            parent.services.catalogChangeService.record(
                .tablesDropped(Array(deletedTables), connectionId: parent.connectionId)
            )
        }

        /// The saving tab reloads only when this save changed its rows: rows it wrote, or a truncate of
        /// the table it shows. A save of table operations alone used to re-run whatever the selected
        /// tab held, which on a query tab executed its statement again. A tab on a dropped table closes.
        /// A tab another change marked stale while it held these edits reloads now they are saved.
        let reloadIndex = parent.tabManager.selectedTabIndex.flatMap { index -> Int? in
            guard savingTabIsSelected, !tab(at: index, shows: deletedTables) else { return nil }
            let changedItsRows = plan.steps.contains(where: { $0.kind == .rowWrite })
                || tab(at: index, shows: truncatedTables)
                || parent.tabSessionRegistry.isStale(parent.tabManager.tabs[index].id)
            return changedItsRows ? index : nil
        }
        announceWrittenTables(
            plan: plan,
            truncatedTables: truncatedTables,
            reloadingTabId: reloadIndex.map { parent.tabManager.tabs[$0].id }
        )
        guard let savedTabIndex = reloadIndex else { return }

        /// An insert or a delete changes the number this tab is reporting, so a count
        /// the user asked for before the save no longer describes the table. Without
        /// retiring it the reload's automatic count refuses to replace it, and the bar
        /// keeps the pre-save total with no `Count Exactly` offered to correct it.
        parent.tabManager.mutate(at: savedTabIndex) { $0.pagination.retireDerivedRowCount() }
        parent.runQuery(viewport: .keepPlace)
    }

    /// Every table this save wrote rows to or truncated, so a tab showing one in this window or
    /// another stops showing the rows as they were. The saving tab reloads itself and is left out.
    private func announceWrittenTables(
        plan: DataWritePlan,
        truncatedTables: Set<DatabaseTreeTableRef>,
        reloadingTabId: UUID?
    ) {
        let connectionId = parent.connectionId
        let adoption = catalogEditAdoption
        var written = Set(plan.steps.filter { $0.kind == .rowWrite }.compactMap { step in
            step.tableName.map { DataWriteTarget(database: plan.scope.database, schema: plan.scope.schema, table: $0) }
        })
        for ref in truncatedTables {
            guard let scope = adoption.objectScope(for: ref, connectionId: connectionId) else { continue }
            written.insert(DataWriteTarget(database: scope.database, schema: scope.schema, table: ref.table.name))
        }
        for target in written {
            AppCommands.shared.objectChanged.send(
                DatabaseObjectChange(
                    connectionId: connectionId,
                    scope: DatabaseScope(connectionId: connectionId, database: target.database, schema: target.schema),
                    name: target.table,
                    kind: .rows,
                    originTabId: reloadingTabId
                )
            )
        }
    }

    /// MySQL, MariaDB and Oracle commit each DROP as it runs, so a save that failed part way can
    /// already have dropped tables its rollback could not bring back. The refreshed catalog says
    /// which, and those are then treated as the drops they were: unstaged, and their tabs closed.
    private func reconcileDropsAfterFailedSave(_ drops: Set<DatabaseTreeTableRef>, scope: DatabaseScope) {
        guard !drops.isEmpty else { return }
        let connectionId = parent.connectionId
        let service = parent.services.catalogChangeService
        let adoption = catalogEditAdoption
        service.record(.changed(CatalogChange(connectionId: connectionId, database: scope.database, kinds: .tables)))
        Task { @MainActor in
            await service.waitUntilIdle(connectionId: connectionId)
            guard let catalog = adoption.loadedBrowseCatalog(connectionId: connectionId) else { return }
            let gone = catalog.staleRefs(in: drops)
            guard !gone.isEmpty else { return }
            service.record(.tablesDropped(Array(gone), connectionId: connectionId))
        }
    }

    /// Matched on the object rather than the bare name, so dropping `analytics.users` says nothing
    /// about a tab on `public.users`.
    private func tab(at index: Int, shows tables: Set<DatabaseTreeTableRef>) -> Bool {
        guard !tables.isEmpty,
              let identity = parent.tabManager.tabs[index].tableIdentity(browsing: parent.browseDatabaseName)
        else { return false }
        let adoption = catalogEditAdoption
        return tables.contains { ref in
            guard let scope = adoption.objectScope(for: ref, connectionId: parent.connectionId) else { return false }
            return TableTabIdentity(table: ref.table.name, database: scope.database, schema: scope.schema) == identity
        }
    }

    private var catalogEditAdoption: CatalogEditAdoption {
        CatalogEditAdoption(
            databaseManager: parent.services.databaseManager,
            schemaService: parent.services.schemaService
        )
    }

    /// Zipped against the steps that ran, not the steps that were planned: the executor drops
    /// blank statements, so pairing on the planned list shifts every later entry's timing and row
    /// count onto the wrong statement.
    private func recordSuccessHistory(
        steps: [DataWriteStep],
        results: [DataWriteStepResult],
        connection: DatabaseConnection,
        scope: DatabaseScope
    ) -> (id: UUID, stored: Task<Bool, Never>)? {
        var firstRowEdit: (id: UUID, stored: Task<Bool, Never>)?
        for (step, result) in zip(steps, results) {
            let historySQL = step.statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = QueryHistoryRecordRequest(
                query: historySQL.hasSuffix(";") ? historySQL : historySQL + ";",
                connectionId: connection.id,
                databaseName: scope.database,
                databaseType: connection.type,
                schemaName: scope.schema,
                source: .rowEdit,
                executionTime: result.executionTime,
                rowCount: result.rowsAffected,
                wasSuccessful: true
            )
            let task = parent.recordHistory(request)
            if firstRowEdit == nil, step.kind == .rowWrite {
                firstRowEdit = (id: request.id, stored: task)
            }
        }
        return firstRowEdit
    }

    /// The foreign-key toggles run outside the transaction, so they are not steps and would
    /// otherwise vanish from history even though they ran against the user's database.
    private func recordSideStatementHistory(
        _ statements: [String],
        connection: DatabaseConnection,
        scope: DatabaseScope
    ) {
        for statement in statements {
            let sql = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty else { continue }
            parent.recordHistory(
                QueryHistoryRecordRequest(
                    query: sql.hasSuffix(";") ? sql : sql + ";",
                    connectionId: connection.id,
                    databaseName: scope.database,
                    databaseType: connection.type,
                    schemaName: scope.schema,
                    source: .rowEdit,
                    executionTime: 0,
                    rowCount: -1,
                    wasSuccessful: true
                )
            )
        }
    }

    /// A statement that committed before the failure is recorded as the success it was.
    ///
    /// Marking the whole batch failed is a lie on any engine without transactions, and it is the
    /// lie that makes the user press Save again and write those rows twice.
    private func recordFailureHistory(
        steps: [DataWriteStep],
        committed: [DataWriteStepResult],
        connection: DatabaseConnection,
        scope: DatabaseScope,
        executionTime: TimeInterval,
        error: any Error
    ) {
        for (offset, step) in steps.enumerated() {
            let sql = step.statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty else { continue }
            /// Only the statement right after the committed ones is the one that failed. Anything
            /// past it never ran, so it is not history at all.
            if offset > committed.count { break }
            let didCommit = offset < committed.count
            parent.recordHistory(
                QueryHistoryRecordRequest(
                    query: sql.hasSuffix(";") ? sql : sql + ";",
                    connectionId: connection.id,
                    databaseName: scope.database,
                    databaseType: connection.type,
                    schemaName: scope.schema,
                    source: .rowEdit,
                    executionTime: didCommit ? committed[offset].executionTime : executionTime,
                    rowCount: didCommit ? committed[offset].rowsAffected : -1,
                    wasSuccessful: didCommit,
                    errorMessage: didCommit ? nil : error.localizedDescription
                )
            )
        }
    }

    /// Keeps what the rows looked like before this save, so it can be offered back.
    ///
    /// Written after the commit and before the change set is cleared, which is the only window
    /// where both the write is known to have happened and the pre-images still exist.
    ///
    /// `history_id` is a foreign key, so the snapshot waits for the history row to be confirmed
    /// written and carries nil when it was not. History capture can be paused, in which case there
    /// is no row to point at and every snapshot would otherwise be rejected outright.
    private func captureRewindRecord(
        plan: DataWritePlan,
        history: (id: UUID, stored: Task<Bool, Never>)?,
        connection: DatabaseConnection
    ) {
        guard parent.services.licenseManager.isFeatureAvailable(.dataRewind) else { return }
        guard AppSettingsManager.shared.history.keepRewindHistory else { return }
        let operations = plan.rowOperations
        guard !operations.isEmpty, let target = operations.first?.target else { return }

        let storage = parent.services.queryHistoryManager
        let generatedColumns = Array(parent.changeManager.generatedColumns)
        let databaseType = connection.type
        let connectionId = connection.id
        let capturedAt = Date()

        Task(priority: .utility) {
            var historyId: UUID?
            if let history, await history.stored.value {
                historyId = history.id
            }
            await storage.recordRewindSnapshot(
                RewindRecord(
                    id: UUID(),
                    historyId: historyId,
                    connectionId: connectionId,
                    databaseType: databaseType,
                    target: target,
                    capturedAt: capturedAt,
                    generatedColumns: generatedColumns,
                    operations: operations
                )
            )
        }
    }

    private func failSave(message: String) {
        endSaveInFlight()
        if let index = parent.tabManager.selectedTabIndex {
            parent.tabManager.mutate(at: index) { $0.execution.errorMessage = message }
        }
        parent.saveCompletionContinuation?.resume(returning: false)
        parent.saveCompletionContinuation = nil
    }

    private func restorePendingTableOperations(
        connectionId: UUID,
        truncates: Set<DatabaseTreeTableRef>,
        deletes: Set<DatabaseTreeTableRef>,
        options: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.restoreStagedTableOperations(truncates: truncates, deletes: deletes, options: options)
        }
    }
}

fileprivate extension RowEditingCoordinator {
    /// The save is owned by the tab that started it, not by whichever tab is selected when it
    /// lands: `failSave` writes into the selected tab, so keying a completion off that would
    /// attribute a slow save to a tab the user switched to while waiting.
    func reportSaveFinished(
        _ outcome: OperationOutcome,
        connection: DatabaseConnection,
        database: String?,
        tabId: UUID?,
        startedAt: ContinuousClock.Instant
    ) {
        guard let tabId else { return }
        parent.reportOperation(
            kind: .rowSave,
            tabId: tabId,
            startedAt: startedAt,
            databaseName: database,
            outcome: outcome
        )
    }
}
