//
//  SchemaSyncScriptBuilder.swift
//  TablePro
//
//  Turns table-level sync operations into dialect-correct statements for the
//  target driver. Ordering across tables follows foreign key dependencies;
//  ordering inside one table is delegated to SchemaStatementGenerator.
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

internal struct SchemaSyncScriptBuilder {
    private let targetDriver: any PluginDatabaseDriver
    private let targetTypeFamily: SQLTypeFamily
    private let scriptText: SQLScriptText
    private let classifier = SyncSafetyClassifier()

    internal init(targetDriver: any PluginDatabaseDriver, targetDatabaseType: DatabaseType) {
        self.targetDriver = targetDriver
        self.targetTypeFamily = SQLTypeFamily.of(targetDatabaseType)
        self.scriptText = SQLScriptText(databaseType: targetDatabaseType)
    }

    internal func build(
        operations: [SchemaSyncOperation],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]]
    ) throws -> [SyncStatement] {
        let ordered = Self.order(operations: operations, foreignKeysByTable: foreignKeysByTable)
        var statements: [SyncStatement] = []
        for operation in ordered {
            statements.append(contentsOf: try build(operation: operation))
        }
        return statements
    }

    internal static func order(
        operations: [SchemaSyncOperation],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]]
    ) -> [SchemaSyncOperation] {
        var drops: [SchemaSyncOperation] = []
        var creates: [SchemaSyncOperation] = []
        var alters: [SchemaSyncOperation] = []
        for operation in operations {
            switch operation {
            case .dropTable: drops.append(operation)
            case .createTable: creates.append(operation)
            case .alterTable: alters.append(operation)
            }
        }
        return sorted(drops, foreignKeysByTable: foreignKeysByTable, childrenFirst: true)
            + sorted(creates, foreignKeysByTable: foreignKeysByTable, childrenFirst: false)
            + sorted(alters, foreignKeysByTable: foreignKeysByTable, childrenFirst: false)
    }

    private static func sorted(
        _ operations: [SchemaSyncOperation],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]],
        childrenFirst: Bool
    ) -> [SchemaSyncOperation] {
        guard operations.count > 1 else { return operations }
        var byIdentifier: [String: [SchemaSyncOperation]] = [:]
        for operation in operations {
            byIdentifier[operation.tableIdentifier, default: []].append(operation)
        }
        let ordered = ForeignKeyTopologicalSort.ordered(
            operations.map { ForeignKeyTopologicalSort.Table(name: $0.tableName, schema: $0.schema) },
            foreignKeysByTable: foreignKeysByTable,
            childrenFirst: childrenFirst
        )
        var emitted: Set<String> = []
        var resolved: [SchemaSyncOperation] = []
        for node in ordered where !emitted.contains(node.identifier) {
            emitted.insert(node.identifier)
            resolved.append(contentsOf: byIdentifier[node.identifier] ?? [])
        }
        return resolved
    }

    private func build(operation: SchemaSyncOperation) throws -> [SyncStatement] {
        switch operation {
        case .createTable(let snapshot):
            return try createStatements(for: snapshot)
        case .dropTable(let name, let schema):
            return dropStatements(name: name, schema: schema)
        case .alterTable(let name, _, let changes):
            return try changeStatements(on: name, objectName: name, changes: changes)
        }
    }

    private func createStatements(for snapshot: TableStructureSnapshot) throws -> [SyncStatement] {
        let definition = PluginCreateTableDefinition(
            tableName: snapshot.name,
            columns: snapshot.columns.map { $0.toPlugin() },
            indexes: snapshot.indexes.filter { !$0.isPrimary }.map { $0.toPlugin() },
            foreignKeys: snapshot.foreignKeys.map { $0.toPlugin() },
            primaryKeyColumns: snapshot.primaryKeyColumns,
            engine: snapshot.engine,
            charset: snapshot.charset,
            collation: snapshot.collation
        )
        if let reason = SchemaOperationRefusal.reason(for: definition, driver: targetDriver) {
            throw CompareSyncError.unsupportedOperation(String(
                format: String(localized: "Cannot create table %@: %@"),
                snapshot.name,
                reason
            ))
        }
        /// Taken from the driver statement by statement rather than divided here: the driver wrote them and knows
        /// where each ends, and Oracle refuses its table and its indexes sent as one call.
        let statements = (targetDriver.generateCreateTableStatements(definition: definition) ?? [])
            .map { StatementBlank.trimming($0) }
            .filter { !$0.isEmpty }
        guard !statements.isEmpty else {
            throw CompareSyncError.unsupportedOperation(String(
                format: String(localized: "The target does not support creating table %@."),
                snapshot.name
            ))
        }
        let summary = String(format: String(localized: "Create table %@"), snapshot.name)
        return statements.map { sql in
            SyncStatement(sql: sql, objectName: snapshot.qualifiedName, summary: summary)
        }
    }

    private func dropStatements(name: String, schema: String?) -> [SyncStatement] {
        guard let sql = targetDriver.dropObjectStatement(
            name: name, objectType: "TABLE", schema: schema, cascade: false
        ) else { return [] }
        let summary = String(format: String(localized: "Drop table %@"), name)
        let hazards = classifier.hazards(forDropping: name)
        return scriptText.sendableStatements(sql).map { statement in
            SyncStatement(sql: statement, objectName: name, summary: summary, hazards: hazards)
        }
    }

    internal func changeStatements(
        on relation: String,
        objectName: String,
        changes: [SchemaChange],
        additionalHazards: (SchemaChange) -> [SyncHazard] = { _ in [] }
    ) throws -> [SyncStatement] {
        let generator = SchemaStatementGenerator(tableName: relation, pluginDriver: targetDriver)
        var statements: [SyncStatement] = []
        for change in SchemaChangeOrdering.sorted(changes) {
            let hazards = classifier.hazards(for: change, typeFamily: targetTypeFamily) + additionalHazards(change)
            let generated = try generator.generate(changes: [change])
            for statement in generated {
                statements += scriptText.sendableStatements(statement.sql).map { sql in
                    SyncStatement(sql: sql, objectName: objectName, summary: statement.description, hazards: hazards)
                }
            }
        }
        return statements
    }
}

internal enum SchemaChangeOrdering {
    internal static func sorted(_ changes: [SchemaChange]) -> [SchemaChange] {
        var buckets: [[SchemaChange]] = Array(repeating: [], count: 10)
        for change in changes {
            buckets[bucket(for: change)].append(change)
        }
        return buckets.flatMap { $0 }
    }

    private static func bucket(for change: SchemaChange) -> Int {
        switch change {
        case .deleteCheckConstraint, .modifyCheckConstraint: return 0
        case .deleteForeignKey, .modifyForeignKey: return 1
        case .deleteIndex, .modifyIndex: return 2
        case .deleteColumn: return 3
        case .modifyColumn: return 4
        case .addColumn: return 5
        case .modifyPrimaryKey: return 6
        case .addIndex: return 7
        case .addForeignKey: return 8
        case .addCheckConstraint: return 9
        }
    }
}

internal enum CompareSyncError: LocalizedError {
    case unsupportedOperation(String)
    case incompatibleEngines(String)
    case noComparisonKey(String)
    case streamOutOfOrder(String)
    case duplicateKey(String)
    case invalidFilter(String)
    case readFailed(String)
    case rowsChangedSinceComparison(String)
    case objectsChangedSinceComparison(String)

    internal var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let message): return message
        case .incompatibleEngines(let message): return message
        case .noComparisonKey(let message): return message
        case .streamOutOfOrder(let message): return message
        case .duplicateKey(let message): return message
        case .invalidFilter(let message): return message
        case .readFailed(let message): return message
        case .rowsChangedSinceComparison(let message): return message
        case .objectsChangedSinceComparison(let message): return message
        }
    }
}
