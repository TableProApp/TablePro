//
//  DataSyncScriptBuilder.swift
//  TablePro
//
//  Turns row differences into DML for the target. Inserts run before updates
//  before deletes, and parent tables before the tables that reference them.
//

import Foundation
import TableProPluginKit

internal struct DataSyncScriptBuilder {
    private let targetDriver: any PluginDatabaseDriver
    private let options: DataCompareOptions

    internal init(targetDriver: any PluginDatabaseDriver, options: DataCompareOptions) {
        self.targetDriver = targetDriver
        self.options = options
    }

    internal func build(
        table: String,
        schema: String?,
        writeColumns: [String],
        entries: [RowDiffEntry]
    ) -> [SyncStatement] {
        var inserts: [SyncStatement] = []
        var updates: [SyncStatement] = []
        var deletes: [SyncStatement] = []

        for entry in entries {
            switch entry.kind {
            case .insert:
                guard options.insertMissingRows, let row = entry.sourceRow else { continue }
                inserts.append(insertStatement(table: table, schema: schema, columns: writeColumns, row: row, entry: entry))
            case .update:
                guard options.updateDifferingRows, let row = entry.sourceRow else { continue }
                guard let statement = updateStatement(
                    table: table, schema: schema, columns: writeColumns, row: row, entry: entry
                ) else { continue }
                updates.append(statement)
            case .delete:
                guard options.deleteExtraRows, let row = entry.targetRow else { continue }
                guard let statement = deleteStatement(table: table, schema: schema, row: row, entry: entry) else { continue }
                deletes.append(statement)
            case .identical:
                continue
            }
        }
        return inserts + updates + deletes
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
        let valueList = columns.map { targetDriver.sqlLiteral(for: row.value(for: $0)) }.joined(separator: ", ")
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
            .map { "\(targetDriver.quoteIdentifier($0)) = \(targetDriver.sqlLiteral(for: row.value(for: $0)))" }
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
                return "\(quoted) = \(targetDriver.sqlLiteral(for: value))"
            }
            .joined(separator: " AND ")
    }
}
