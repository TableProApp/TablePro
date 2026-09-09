//
//  StructureColumnReorderHandler.swift
//  TablePro
//
//  Turns a drag in the Structure tab's column list into the statements that reorder the table.
//

import Foundation
import TableProPluginKit

@MainActor
enum StructureColumnReorderHandler {
    enum ReorderError: LocalizedError {
        case notSupported
        case invalidIndices
        case sqlGenerationFailed

        var errorDescription: String? {
            switch self {
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

    /// Runs a prepared reorder through the shared plan runner.
    static func execute(
        _ prepared: PreparedReorder,
        tableName: String,
        databaseType: DatabaseType
    ) async throws {
        try await StructureRebuildPlanRunner.execute(
            StructureRebuildPlanRunner.Prepared(
                plan: prepared.plan,
                fingerprint: prepared.fingerprint,
                scope: prepared.scope,
                tableName: tableName
            ),
            databaseType: databaseType,
            operationDescription: String(localized: "Reorder Columns")
        )
    }
}
