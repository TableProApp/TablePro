//
//  StructureColumnReorderHandler.swift
//  TablePro
//
//  Turns a drag in the Structure tab's column list into the statements that reorder the table.
//

import Foundation
import os
import TableProPluginKit

@MainActor
enum StructureColumnReorderHandler {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "StructureColumnReorderHandler")

    enum ReorderError: LocalizedError {
        case noDriver
        case notSupported
        case invalidIndices
        case sqlGenerationFailed
        case schemaChanged
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDriver:
                return String(localized: "No active database connection")
            case .notSupported:
                return String(localized: "Column reorder is not supported for this database type")
            case .invalidIndices:
                return String(localized: "Invalid column indices for reorder operation")
            case .sqlGenerationFailed:
                return String(
                    localized: """
                        Could not build the column reorder for this table. If this engine's driver \
                        was installed before column reorder shipped, update it in Settings > Plugins.
                        """
                )
            case .schemaChanged:
                return String(
                    localized: """
                        The table changed while the script was open. Nothing was run. Close and \
                        reopen the structure tab, then try again.
                        """
                )
            case .executionFailed(let message):
                return String(format: String(localized: "Column reorder failed: %@"), message)
            }
        }
    }

    /// A plan and the fingerprint of the schema it was built from.
    ///
    /// The fingerprint is what makes a reviewed rebuild safe to run later: a plan ends in a `DROP`,
    /// and anything another connection added while the sheet was open is inside the table the plan
    /// is about to drop and absent from the one that replaces it.
    struct PreparedReorder {
        let plan: PluginColumnReorderPlan
        let fingerprint: String?
        let scope: DatabaseScope
    }

    /// The order a drag asks for, as column names.
    ///
    /// - Parameters:
    ///   - fromIndex: The source row index in the NSTableView (0-based).
    ///   - toIndex: The drop target row index from NSTableView's `acceptDrop`, which is the row
    ///     ABOVE which the item will be inserted, so it may equal `count`.
    static func desiredOrder(
        fromIndex: Int,
        toIndex: Int,
        columnNames: [String]
    ) throws -> [String] {
        guard fromIndex >= 0, fromIndex < columnNames.count,
              toIndex >= 0, toIndex <= columnNames.count else {
            throw ReorderError.invalidIndices
        }
        var names = columnNames
        let moving = names.remove(at: fromIndex)
        /// Removing the source shifts everything below it up by one, so a drop below the source
        /// lands one position too low unless the insertion point moves with it.
        let insertionIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        names.insert(moving, at: insertionIndex)
        return names
    }

    /// Asks the driver for the statements that produce `desiredOrder`.
    ///
    /// Runs on the tab's own scope, never on whichever database the connection's shared driver
    /// happens to be pointed at. Another tab or window can move that driver between the drag and
    /// the drop, and an unqualified `DROP TABLE` would then land on a same-named table elsewhere.
    ///
    /// Nothing is executed here. A plan whose cost is a table rebuild is reviewed and confirmed
    /// before it runs, and only the caller knows which of the two it is looking at.
    static func prepare(
        desiredOrder: [String],
        workingColumns: [EditableColumnDefinition],
        tableName: String,
        scope: DatabaseScope
    ) async throws -> PreparedReorder {
        let columns = workingColumns.map { $0.toPlugin() }
        let schema = scope.schema

        let prepared = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .untracked
        ) { driver in
            guard let adapter = driver as? PluginDriverAdapter else {
                throw ReorderError.notSupported
            }
            let plan = try await adapter.generateColumnReorderPlan(
                table: tableName,
                schema: schema,
                columns: columns,
                desiredOrder: desiredOrder
            )
            guard let plan, !plan.statements.isEmpty else {
                throw ReorderError.sqlGenerationFailed
            }
            let fingerprint = try? await adapter.columnReorderSchemaFingerprint(
                table: tableName, schema: schema
            )
            return (plan, fingerprint)
        }

        return PreparedReorder(plan: prepared.0, fingerprint: prepared.1, scope: scope)
    }

    /// Runs a prepared reorder, once, on the scope it was planned against.
    ///
    /// Authorization happens once for the whole plan, before any statement runs, and deliberately
    /// outside the scoped block: it can await a confirmation sheet and Touch ID, and holding the
    /// connection's driver across a human prompt would freeze every other tab on it. Asking per
    /// statement was worse than slow, it was wrong: a user could approve through a rebuild's last
    /// write and decline the statement after it, by which point there was nothing left to refuse.
    static func execute(
        _ prepared: PreparedReorder,
        tableName: String,
        databaseType: DatabaseType
    ) async throws {
        let plan = prepared.plan
        let scope = prepared.scope
        let combined = plan.scriptStatements.joined(separator: "\n")

        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: scope.connectionId,
                databaseType: databaseType,
                sql: combined,
                kind: plan.cost == .tableRebuild ? .destructiveQuery : .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Reorder Columns")
            )
        )
        guard case .authorized = decision else {
            throw DatabaseError.queryFailed(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        let expectedFingerprint = prepared.fingerprint
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            if let expectedFingerprint,
               let adapter = driver as? PluginDriverAdapter,
               let current = try? await adapter.columnReorderSchemaFingerprint(
                   table: tableName, schema: scope.schema
               ),
               current != expectedFingerprint {
                throw ReorderError.schemaChanged
            }

            for sql in plan.prologue {
                _ = try? await driver.execute(query: sql)
            }

            /// Only the transaction this plan opened is ever rolled back. Rolling back
            /// unconditionally would discard a transaction the user had already opened on the same
            /// session and never committed.
            let usesTransaction = plan.isTransactional && driver.supportsTransactions
            if usesTransaction {
                try await driver.beginTransaction(mode: .readWrite)
            }

            var completed = 0
            do {
                for sql in plan.statements {
                    logger.info("Reordering columns: \(sql, privacy: .public)")
                    _ = try await driver.execute(query: sql)
                    completed += 1
                }
                if usesTransaction {
                    try await driver.commitTransaction()
                }
            } catch {
                if usesTransaction {
                    do {
                        try await driver.rollbackTransaction()
                    } catch {
                        logger.error("Column reorder rollback failed: \(error.localizedDescription, privacy: .public)")
                    }
                } else if completed > 0 {
                    /// An engine whose DDL commits statement by statement has nothing to roll back,
                    /// so it supplies statements that put back what already ran.
                    for sql in plan.compensation {
                        _ = try? await driver.execute(query: sql)
                    }
                }
                for sql in plan.epilogue {
                    _ = try? await driver.execute(query: sql)
                }
                throw ReorderError.executionFailed(error.localizedDescription)
            }

            for sql in plan.epilogue {
                _ = try? await driver.execute(query: sql)
            }
        }
    }
}
