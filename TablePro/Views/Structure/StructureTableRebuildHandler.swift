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
/// any version, so a save that touches one has to recreate the table, and the edits staged
/// alongside it travel in the same rebuild rather than running as separate `ALTER`s first. Two
/// passes would leave the earlier changes committed when the rebuild failed, and a column the save
/// renamed would leave the staged foreign key naming a column that no longer exists.
///
/// A rename and a drop travel as their own `ALTER TABLE`, appended after the rebuild rather than
/// folded into the new definition. That is not a shortcut: `ALTER TABLE` rewrites the column's name
/// through every index, trigger and view itself, measured on 3.54, and a rebuild that reproduced
/// the table by hand would leave all three naming a column that no longer exists.
@MainActor
enum StructureTableRebuildHandler {
    enum RebuildError: LocalizedError {
        case notRebuildable(String)
        case cannotExpress([String])
        case namingConflict(String)
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
                            A foreign key change recreates the table, and these cannot travel with \
                            it:\n\n%@\n\nSave them on their own first, then change the foreign key.
                            """
                    ),
                    descriptions.joined(separator: "\n")
                )
            case .namingConflict(let name):
                return String(
                    format: String(
                        localized: """
                            This save reuses the column name %@ while the table is being recreated, \
                            and the recreated table would hold it twice. Save the change that frees \
                            the name first, then the one that takes it.
                            """
                    ),
                    name
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
            case .addForeignKey, .modifyForeignKey, .deleteForeignKey:
                true
            case .modifyColumn(let old, let new):
                /// A rename alone is an `ALTER TABLE`, which is cheaper than copying the table and
                /// carries itself into every dependent object. Anything else about a column needs
                /// the table recreated, because SQLite has no statement for it.
                old.alteration(comparedTo: new) != nil
            default:
                false
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
        guard let conflict = respecification.namingConflict else {
            return try await prepare(respecification, changes: partition, tableName: tableName, scope: scope)
        }
        throw RebuildError.namingConflict(conflict)
    }

    private static func prepare(
        _ respecification: PluginTableRespecification,
        changes partition: Partition,
        tableName: String,
        scope: DatabaseScope
    ) async throws -> StructureRebuildPlanRunner.Prepared {
        let schema = scope.schema
        let partitionTrailing = partition.trailing

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
                .generate(changes: partitionTrailing)
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
                if old.changesFieldsNoRebuildCarries(comparedTo: new) {
                    partition.unsupported.append(change)
                } else {
                    partition.rebuilt.append(change)
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
        var alteredColumns: [PluginColumnAlteration] = []
        var addedForeignKeys: [PluginForeignKeyDefinition] = []
        var droppedForeignKeys: [PluginForeignKeyDefinition] = []

        for change in changes {
            switch change {
            case .addColumn(let column):
                addedColumns.append(column.toPlugin())
            case .deleteColumn(let column):
                droppedColumns.append(column.name)
            case .modifyColumn(let old, let new):
                /// A column edit is up to three separate things, and they leave by different doors.
                /// The type, nullability and default go into the new definition; the rename becomes
                /// an `ALTER TABLE` after it. One `.modifyColumn` can carry both.
                if old.name != new.name { renamedColumns[old.name] = new.name }
                if let alteration = old.alteration(comparedTo: new) {
                    alteredColumns.append(alteration)
                }
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
            droppedForeignKeys: droppedForeignKeys,
            alteredColumns: alteredColumns
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
    /// What changed about this column beyond its name, or nil when only the name did.
    ///
    /// A rename leaves by a different door: `ALTER TABLE RENAME COLUMN` carries it into every
    /// index, trigger and view, which a rebuilt definition cannot. Everything here has no `ALTER`
    /// behind it on a rebuild engine, so it travels in the new definition instead.
    ///
    /// The default is compared as the user's own text and passed on the same way. A default read
    /// back from `PRAGMA table_info` has already lost its parentheses, and measured on 3.54 the
    /// stripped form of `DEFAULT (datetime('now'))` will not parse again, so an unchanged one must
    /// never be re-rendered from a model.
    func alteration(comparedTo other: EditableColumnDefinition) -> PluginColumnAlteration? {
        let type = dataType == other.dataType ? nil : other.dataType
        let isNullable = self.isNullable == other.isNullable ? nil : other.isNullable
        let defaultValue = defaultValue == other.defaultValue ? nil : (other.defaultValue ?? "")

        guard type != nil || isNullable != nil || defaultValue != nil else { return nil }
        return PluginColumnAlteration(
            column: name, type: type, isNullable: isNullable, defaultValue: defaultValue
        )
    }

    /// Whether this edit touches a field the rebuild cannot carry.
    ///
    /// A single `.modifyColumn` folds every field the user changed on that row, and the rebuild
    /// expresses three of them. Applying the three and dropping the rest would report success over
    /// an edit it never made, which is the defect this whole change exists to remove. Setting
    /// Primary Key on a nullable column is the case that bites: the editor flips nullability with
    /// it, so the save would rebuild the table `NOT NULL` and quietly leave the key unset.
    func changesFieldsNoRebuildCarries(comparedTo other: EditableColumnDefinition) -> Bool {
        isPrimaryKey != other.isPrimaryKey
            || autoIncrement != other.autoIncrement
            || generationExpression != other.generationExpression
            || generationKind != other.generationKind
    }
}
