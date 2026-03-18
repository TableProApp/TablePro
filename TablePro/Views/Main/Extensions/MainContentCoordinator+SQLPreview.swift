//
//  MainContentCoordinator+SQLPreview.swift
//  TablePro
//
//  SQL preview generation for MainContentCoordinator.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - SQL Preview

    /// Routes SQL preview request to the appropriate handler based on current tab mode
    func handlePreviewSQL(
        pendingTruncates: Set<String>,
        pendingDeletes: Set<String>,
        tableOperationOptions: [String: TableOperationOptions]
    ) {
        if tabManager.selectedTab?.showStructure == true {
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
        pendingTruncates: Set<String>,
        pendingDeletes: Set<String>,
        tableOperationOptions: [String: TableOperationOptions]
    ) {
        do {
            let statements = try assemblePendingStatements(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
            toolbarState.previewStatements = statements.map {
                SQLParameterInliner.inline($0, databaseType: connection.type)
            }
        } catch {
            toolbarState.previewStatements = ["-- Error generating SQL: \(error.localizedDescription)"]
        }
        toolbarState.showSQLReviewPopover = true
    }

    /// Assembles all pending SQL statements (cell edits + table operations) in execution order.
    /// Used by both `saveChanges()` and `generatePreviewSQL()` to ensure consistency.
    /// Transaction wrapping is handled by the caller using driver protocol methods.
    func assemblePendingStatements(
        pendingTruncates: Set<String>,
        pendingDeletes: Set<String>,
        tableOperationOptions: [String: TableOperationOptions]
    ) throws -> [ParameterizedStatement] {
        var allStatements: [ParameterizedStatement] = []
        let dbType = connection.type

        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        // Check if any table operation needs FK disabled (must be outside transaction)
        let needsDisableFK = PluginManager.shared.supportsForeignKeyDisable(for: dbType) && pendingTruncates.union(pendingDeletes).contains { tableName in
            tableOperationOptions[tableName]?.ignoreForeignKeys == true
        }

        // FK disable must be FIRST, before any transaction begins
        if needsDisableFK {
            allStatements.append(contentsOf: fkDisableStatements(for: dbType).map {
                ParameterizedStatement(sql: $0, parameters: [])
            })
        }

        if changeManager.hasChanges {
            let editStatements = try changeManager.generateSQL()
            allStatements.append(contentsOf: editStatements)
        }

        if hasPendingTableOps {
            let tableOpStatements = generateTableOperationSQL(
                truncates: pendingTruncates,
                deletes: pendingDeletes,
                options: tableOperationOptions,
                includeFKHandling: false
            )
            allStatements.append(contentsOf: tableOpStatements.map {
                ParameterizedStatement(sql: $0, parameters: [])
            })
        }

        // FK re-enable must be LAST, after transaction commits
        if needsDisableFK {
            allStatements.append(contentsOf: fkEnableStatements(for: dbType).map {
                ParameterizedStatement(sql: $0, parameters: [])
            })
        }

        return allStatements
    }
}
