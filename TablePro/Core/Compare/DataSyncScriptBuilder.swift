//
//  DataSyncScriptBuilder.swift
//  TablePro
//
//  Turns row differences into DML for the target. Inserts run before updates
//  before deletes, and parent tables before the tables that reference them.
//

import Foundation
import TableProPluginKit

/// One table's DML, kept in three buckets so the caller can interleave several tables in
/// dependency order. A flat `inserts + updates + deletes` per table is only correct for one
/// table: across tables it puts a child's insert before its parent's, which the server refuses.
internal struct DataSyncStatements {
    internal var inserts: [SyncStatement] = []
    internal var updates: [SyncStatement] = []
    internal var deletes: [SyncStatement] = []

    internal var isEmpty: Bool {
        inserts.isEmpty && updates.isEmpty && deletes.isEmpty
    }

    internal var flattened: [SyncStatement] {
        inserts + updates + deletes
    }
}

internal struct DataSyncScriptBuilder {
    private let targetDriver: any PluginDatabaseDriver
    private let targetDatabaseType: DatabaseType
    private let options: DataCompareOptions

    internal init(
        targetDriver: any PluginDatabaseDriver,
        targetDatabaseType: DatabaseType,
        options: DataCompareOptions
    ) {
        self.targetDriver = targetDriver
        self.targetDatabaseType = targetDatabaseType
        self.options = options
    }

    internal func build(
        table: String,
        schema: String?,
        writeColumns: [String],
        entries: [RowDiffEntry]
    ) -> [SyncStatement] {
        var statements = DataSyncStatements()
        for entry in entries {
            append(entry, table: table, schema: schema, writeColumns: writeColumns, into: &statements)
        }
        return statements.flattened
    }

    internal func append(
        _ entry: RowDiffEntry,
        table: String,
        schema: String?,
        writeColumns: [String],
        into statements: inout DataSyncStatements
    ) {
        switch entry.kind {
        case .insert:
            guard options.insertMissingRows, let row = entry.sourceRow else { return }
            statements.inserts.append(
                insertStatement(table: table, schema: schema, columns: writeColumns, row: row, entry: entry)
            )
        case .update:
            guard options.updateDifferingRows, let row = entry.sourceRow else { return }
            guard let statement = updateStatement(
                table: table, schema: schema, columns: writeColumns, row: row, entry: entry
            ) else { return }
            statements.updates.append(statement)
        case .delete:
            guard options.deleteExtraRows, let row = entry.targetRow else { return }
            guard let statement = deleteStatement(table: table, schema: schema, row: row, entry: entry) else { return }
            statements.deletes.append(statement)
        case .identical:
            return
        }
    }

    private func literal(for value: PluginCellValue) -> String {
        CompareSQLLiteral.literal(for: value, databaseType: targetDatabaseType, driver: targetDriver)
    }

    private func qualified(_ table: String, _ schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return targetDriver.quoteIdentifier(table) }
        return "\(targetDriver.quoteIdentifier(schema)).\(targetDriver.quoteIdentifier(table))"
    }

    private func insertStatement(
        table: String,
        schema: String?,
        columns: [String],
        row: DataRow,
        entry: RowDiffEntry
    ) -> SyncStatement {
        let columnList = columns.map { targetDriver.quoteIdentifier($0) }.joined(separator: ", ")
        let valueList = columns.map { literal(for: row.value(for: $0)) }.joined(separator: ", ")
        return SyncStatement(
            sql: "INSERT INTO \(qualified(table, schema)) (\(columnList)) VALUES (\(valueList));",
            objectName: table,
            summary: String(format: String(localized: "Insert row %@ into %@"), entry.keyDescription, table)
        )
    }

    private func updateStatement(
        table: String,
        schema: String?,
        columns: [String],
        row: DataRow,
        entry: RowDiffEntry
    ) -> SyncStatement? {
        let keySet = Set(options.keyColumns.map { $0.lowercased() })
        let assignable = columns.filter { !keySet.contains($0.lowercased()) }
        guard !assignable.isEmpty else { return nil }
        let assignments = assignable
            .map { "\(targetDriver.quoteIdentifier($0)) = \(literal(for: row.value(for: $0)))" }
            .joined(separator: ", ")
        guard let predicate = keyPredicate(row: row) else { return nil }
        return SyncStatement(
            sql: "UPDATE \(qualified(table, schema)) SET \(assignments) WHERE \(predicate);",
            objectName: table,
            summary: String(format: String(localized: "Update row %@ in %@"), entry.keyDescription, table)
        )
    }

    private func deleteStatement(
        table: String,
        schema: String?,
        row: DataRow,
        entry: RowDiffEntry
    ) -> SyncStatement? {
        guard let predicate = keyPredicate(row: row) else { return nil }
        return SyncStatement(
            sql: "DELETE FROM \(qualified(table, schema)) WHERE \(predicate);",
            objectName: table,
            summary: String(format: String(localized: "Delete row %@ from %@"), entry.keyDescription, table),
            hazards: [SyncHazard(
                kind: .dataLoss,
                severity: .refusedByDefault,
                explanation: String(
                    format: String(localized: "Deleting row %@ from %@ permanently removes it."),
                    entry.keyDescription, table
                )
            )]
        )
    }

    private func keyPredicate(row: DataRow) -> String? {
        guard !options.keyColumns.isEmpty else { return nil }
        return options.keyColumns
            .map { column -> String in
                let quoted = targetDriver.quoteIdentifier(column)
                let value = row.value(for: column)
                if case .null = value { return "\(quoted) IS NULL" }
                return "\(quoted) = \(literal(for: value))"
            }
            .joined(separator: " AND ")
    }
}
