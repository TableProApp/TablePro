//
//  StructureTableRebuildHandler.swift
//  TablePro
//
//  Turns a save the engine cannot express as ALTER statements into one reviewed table rebuild.
//

import Foundation
import TableProPluginKit

/// Builds the plan for a save on an engine that changes a table by recreating it.
///
/// SQLite and its derivatives are the case. Their `ALTER TABLE` cannot add or drop a foreign key at
/// any version, so a save that touches one has to recreate the table, and the column edits staged
/// alongside it have to travel in the same rebuild rather than running as separate `ALTER`s first.
/// Two passes would leave the column changes committed when the rebuild failed, and a column the
/// save renames would leave the staged foreign key naming a column that no longer exists.
@MainActor
enum StructureTableRebuildHandler {
    enum RebuildError: LocalizedError {
        case notRebuildable(String)
        case cannotExpress([String])
        case planFailed

        var errorDescription: String? {
            switch self {
            case .notRebuildable(let table):
                return String(
                    format: String(
                        localized: """
                            This change needs %@ to be recreated, and it cannot be recreated from \
                            the definition the database stored for it. Virtual tables, such as \
                            full-text search tables, are the usual reason.
                            """
                    ),
                    table
                )
            case .cannotExpress(let descriptions):
                return String(
                    format: String(
                        localized: """
                            This database cannot make these changes through the structure editor:\n\n%@\
                            \n\nRemove them from this save, or write the SQL yourself in a query tab.
                            """
                    ),
                    descriptions.joined(separator: "\n")
                )
            case .planFailed:
                return String(
                    localized: """
                        Could not build the table rebuild for this change. If this engine's driver \
                        was installed before foreign key editing shipped, update it in \
                        Settings > Plugins.
                        """
                )
            }
        }
    }

    /// Whether a save has to go through a rebuild rather than the statement-per-change path.
    ///
    /// Only a foreign key change forces one. Every other edit the structure editor offers on these
    /// engines has an `ALTER` behind it, and running one is cheaper than copying the table.
    static func requiresRebuild(changes: [SchemaChange], support: ForeignKeyEditSupport) -> Bool {
        support == .rebuild && changes.contains { change in
            switch change {
            case .addForeignKey, .modifyForeignKey, .deleteForeignKey: true
            default: false
            }
        }
    }

    static func prepare(
        changes: [SchemaChange],
        tableName: String,
        scope: DatabaseScope
    ) async throws -> StructureRebuildPlanRunner.Prepared {
        let partition = partition(changes)
        guard partition.unsupported.isEmpty else {
            throw RebuildError.cannotExpress(partition.unsupported.map(\.description))
        }

        let respecification = respecification(from: partition.rebuilt)
        let schema = scope.schema

        let prepared = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .untracked
        ) { driver in
            guard let adapter = driver as? PluginDriverAdapter else { throw RebuildError.planFailed }
            guard let plan = try await adapter.generateTableRebuildPlan(
                table: tableName,
                schema: schema,
                respecification: respecification
            ) else {
                throw RebuildError.notRebuildable(tableName)
            }
            let pluginDriver = adapter.schemaPluginDriver

            /// An index or a check constraint is its own object, created after the table exists, so
            /// it rides at the end of the same transaction rather than forcing a second one. A drop
            /// lands after the rebuild has replayed the indexes it inherited, which is what makes it
            /// take effect rather than being undone by the replay.
            let trailing = try SchemaStatementGenerator(tableName: tableName, pluginDriver: pluginDriver)
                .generate(changes: partition.trailing)
                .map(\.sql)

            let fingerprint = try? await adapter.columnReorderSchemaFingerprint(
                table: tableName, schema: schema
            )
            return (plan.appending(statements: trailing), fingerprint)
        }

        return StructureRebuildPlanRunner.Prepared(
            plan: prepared.0,
            fingerprint: prepared.1,
            scope: scope,
            tableName: tableName
        )
    }

    // MARK: - Partitioning

    private struct Partition {
        var rebuilt: [SchemaChange] = []
        var trailing: [SchemaChange] = []
        var unsupported: [SchemaChange] = []
    }

    /// Splits a save into the edits the new table definition carries, the ones that run as their own
    /// statements afterwards, and the ones this engine cannot make at all.
    private static func partition(_ changes: [SchemaChange]) -> Partition {
        var partition = Partition()
        for change in changes {
            switch change {
            case .addColumn, .deleteColumn, .addForeignKey, .modifyForeignKey, .deleteForeignKey:
                partition.rebuilt.append(change)
            case .modifyColumn(let old, let new):
                /// A rename is a new name on the same definition, which the rebuild writes into the
                /// column's own stored text. Anything else means rewriting a definition the stored
                /// text is the only full record of, which needs a column parser this does not have.
                if old.isRenameOnly(comparedTo: new) {
                    partition.rebuilt.append(change)
                } else {
                    partition.unsupported.append(change)
                }
            case .addIndex, .modifyIndex, .deleteIndex,
                 .addCheckConstraint, .modifyCheckConstraint, .deleteCheckConstraint:
                partition.trailing.append(change)
            case .modifyPrimaryKey:
                partition.unsupported.append(change)
            }
        }
        return partition
    }

    private static func respecification(from changes: [SchemaChange]) -> PluginTableRespecification {
        var addedColumns: [PluginColumnDefinition] = []
        var droppedColumns: [String] = []
        var renamedColumns: [String: String] = [:]
        var addedForeignKeys: [PluginForeignKeyDefinition] = []
        var droppedForeignKeys: [PluginForeignKeyDefinition] = []

        for change in changes {
            switch change {
            case .addColumn(let column):
                addedColumns.append(column.toPlugin())
            case .deleteColumn(let column):
                droppedColumns.append(column.name)
            case .modifyColumn(let old, let new):
                renamedColumns[old.name] = new.name
            case .addForeignKey(let foreignKey):
                addedForeignKeys.append(foreignKey.toPlugin())
            case .deleteForeignKey(let foreignKey):
                droppedForeignKeys.append(foreignKey.toPlugin())
            case .modifyForeignKey(let old, let new):
                droppedForeignKeys.append(old.toPlugin())
                addedForeignKeys.append(new.toPlugin())
            default:
                continue
            }
        }

        return PluginTableRespecification(
            addedColumns: addedColumns,
            droppedColumns: droppedColumns,
            renamedColumns: renamedColumns,
            addedForeignKeys: addedForeignKeys,
            droppedForeignKeys: droppedForeignKeys
        )
    }
}

private extension PluginColumnReorderPlan {
    func appending(statements extra: [String]) -> PluginColumnReorderPlan {
        guard !extra.isEmpty else { return self }
        return PluginColumnReorderPlan(
            statements: statements + extra,
            prologue: prologue,
            epilogue: epilogue,
            compensation: compensation,
            isTransactional: isTransactional,
            cost: cost,
            caveats: caveats,
            isRunnable: isRunnable,
            verifications: verifications
        )
    }
}

internal extension EditableColumnDefinition {
    /// Whether `other` differs from this column in nothing but its name.
    ///
    /// The identifier is excluded because an edit keeps the row it was made on, so the two always
    /// carry the same one.
    func isRenameOnly(comparedTo other: EditableColumnDefinition) -> Bool {
        var renamed = self
        renamed.name = other.name
        renamed.id = other.id
        return renamed == other && name != other.name
    }
}
