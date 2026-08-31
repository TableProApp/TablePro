//
//  MainContentCoordinator+SQLPreview.swift
//  TablePro
//
//  Building the plan for a save, and showing it.
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    // MARK: - SQL Preview

    /// Routes SQL preview request to the appropriate handler based on current tab mode
    func handlePreviewSQL(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        if tabManager.selectedTab?.display.resultsViewMode == .structure {
            // Structure view handles its own preview via direct call
            structureActions?.previewSQL?()
        } else {
            generatePreviewSQL(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        }
    }

    /// Generate SQL preview of all pending changes with inlined parameters
    func generatePreviewSQL(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        do {
            let plan = try buildDataWritePlan(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
            toolbarState.previewStatements = plan.displayStatements
        } catch {
            toolbarState.previewStatements = ["-- Error generating SQL: \(error.localizedDescription)"]
        }
        activeSheet = .sqlPreview
    }

    /// Hands the rebuild script to a query tab so the user can read, edit and run it themselves.
    ///
    /// The rebuild reproduces the table from what the server will describe, so a table using
    /// something the catalog queries do not reach is better rebuilt by hand from a script the user
    /// owns than by a button that reports success.
    /// Opened on the scope the plan was built against, not on whatever the connection is browsing.
    /// The script names its table without a database, and PostgreSQL has no way to qualify one, so
    /// running it against another database would rebuild the same-named table there.
    func openColumnReorderScriptInEditor(_ request: ColumnReorderReviewRequest) {
        let script = request.scriptStatements
            .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
            .joined(separator: "\n\n")
        WindowManager.shared.openTab(
            payload: EditorTabPayload(
                connectionId: request.scope.connectionId,
                tabType: .query,
                databaseName: request.scope.database,
                schemaName: request.scope.schema,
                initialQuery: script,
                skipAutoExecute: true,
                tabTitle: String(format: String(localized: "Reorder %@"), request.tableName)
            )
        )
        columnReorderRequest = nil
        activeSheet = nil
    }

    /// Everything one press of Save is about to do, in execution order.
    ///
    /// Save and Preview SQL both read this, so what the user is shown is what runs. Each step
    /// carries the rows it should touch, which is what lets the executor hold the server to that
    /// number, and the row operations carry the before and after images a later rewind needs.
    func buildDataWritePlan(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) throws -> DataWritePlan {
        let dbType = connection.type
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty
        var steps: [DataWriteStep] = []

        /// The foreign-key toggles are not steps. A step runs inside the transaction, and
        /// `PRAGMA foreign_keys` is a no-op there on every SQLite-derived engine, so the option
        /// would silently do nothing. They travel as the plan's prologue and epilogue instead.
        let needsDisableFK = PluginManager.shared.supportsForeignKeyDisable(for: dbType)
            && pendingTruncates.union(pendingDeletes).contains { ref in
                tableOperationOptions[ref]?.ignoreForeignKeys == true
            }
        let prologue = needsDisableFK ? fkDisableStatements(for: dbType) : []
        let epilogue = needsDisableFK ? fkEnableStatements(for: dbType) : []

        let scope = try writeScope(
            stagedTables: pendingTruncates.union(pendingDeletes),
            includesRowEdits: changeManager.hasChanges
        )

        var rowOperations: [RowWriteOperation] = []
        if changeManager.hasChanges {
            /// The scope's schema, not the tab's: the scope has already fallen back to the session's
            /// browse schema, and a record stored under one spelling is never found under the other.
            let rowWrite = try changeManager.buildRowWrites(
                database: scope.database,
                schema: scope.schema,
                containsTableOperation: hasPendingTableOps
            )
            steps.append(contentsOf: rowWrite.steps)
            rowOperations = rowWrite.operations
        }

        if hasPendingTableOps {
            let tableOpStatements = generateTableOperationSQL(
                truncates: pendingTruncates,
                deletes: pendingDeletes,
                options: tableOperationOptions,
                includeFKHandling: false
            )
            steps.append(contentsOf: tableOpStatements.map {
                DataWriteStep(kind: .tableOperation, statement: ParameterizedStatement(sql: $0, parameters: []))
            })
        }

        return DataWritePlan(
            scope: scope,
            databaseType: dbType,
            steps: steps,
            rowOperations: rowOperations,
            prologue: prologue,
            epilogue: epilogue
        )
    }

    private func writeScope(
        stagedTables: Set<DatabaseTreeTableRef>,
        includesRowEdits: Bool
    ) throws -> DatabaseScope {
        try StagedWriteScope.resolve(
            tabScope: selectedTabScope ?? DatabaseScope(connectionId: connection.id, database: "", schema: nil),
            browseDatabase: browseDatabaseName,
            stagedDatabases: Set(stagedTables.compactMap(\.database)),
            includesRowEdits: includesRowEdits
        )
    }

    /// Assembles all pending SQL statements (cell edits + table operations) in execution order.
    func assemblePendingStatements(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) throws -> [ParameterizedStatement] {
        try buildDataWritePlan(
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions
        ).statements
    }
}
