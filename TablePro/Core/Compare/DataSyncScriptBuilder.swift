//
//  DataSyncScriptBuilder.swift
//  TablePro
//
//  Turns one table's row differences into DML for the target. Inserts run
//  before updates before deletes, and parent tables before the tables that
//  reference them.
//

import Foundation
import TableProPluginKit

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
    private enum IdentityInsertStyle {
        case plain
        case overridingSystemValue
        case identityInsertSession
    }

    private let targetDriver: any PluginDatabaseDriver
    private let targetDatabaseType: DatabaseType
    private let options: DataCompareOptions
    private let plan: DataComparePlan
    private let targetTypes: [String: ColumnType]

    internal init(
        targetDriver: any PluginDatabaseDriver,
        targetDatabaseType: DatabaseType,
        options: DataCompareOptions,
        plan: DataComparePlan
    ) {
        self.targetDriver = targetDriver
        self.targetDatabaseType = targetDatabaseType
        self.options = options
        self.plan = plan
        var types: [String: ColumnType] = [:]
        for column in plan.columns {
            guard let type = column.targetColumnType else { continue }
            types[column.name.lowercased()] = type
        }
        self.targetTypes = types
    }

    internal func build(entries: [RowDiffEntry]) -> [SyncStatement] {
        var statements = DataSyncStatements()
        for entry in entries {
            append(entry, into: &statements)
        }
        finish(&statements)
        return statements.flattened
    }

    internal func append(_ entry: RowDiffEntry, into statements: inout DataSyncStatements) {
        guard options.writesRows(of: entry.kind) else { return }
        /// A row whose only difference sits in a column the target computes has nothing to write:
        /// the statement would set every other column to the value it already holds.
        if entry.kind == .update, !entry.cellDifferences.isEmpty,
           !entry.cellDifferences.contains(where: { plan.updatableColumns.contains($0.column) }) {
            return
        }
        switch entry.kind {
        case .insert:
            guard let row = entry.sourceRow else { return }
            statements.inserts.append(insertStatement(row: row, entry: entry))
        case .update:
            guard let source = entry.sourceRow, let target = entry.targetRow,
                  let statement = updateStatement(source: source, target: target, entry: entry) else { return }
            statements.updates.append(statement)
        case .delete:
            guard let row = entry.targetRow, let statement = deleteStatement(row: row, entry: entry) else { return }
            statements.deletes.append(statement)
        case .identical, .conflict:
            return
        }
    }

    internal func finish(_ statements: inout DataSyncStatements) {
        guard !statements.inserts.isEmpty, identityInsertStyle == .identityInsertSession else { return }
        let table = qualifiedTable
        let scope = "identity-insert|\(plan.targetSchema ?? "")|\(plan.table)"
        let closingSQL = "SET IDENTITY_INSERT \(table) OFF"
        let open = SyncStatement(
            sql: "SET IDENTITY_INSERT \(table) ON",
            objectName: plan.id,
            summary: String(format: String(localized: "Allow explicit identity values in %@"), plan.table),
            sessionEffect: .opens(scope: scope, closingSQL: closingSQL)
        )
        let close = SyncStatement(
            sql: closingSQL,
            objectName: plan.id,
            summary: String(format: String(localized: "Stop allowing explicit identity values in %@"), plan.table),
            sessionEffect: .closes(scope: scope)
        )
        statements.inserts = [open] + statements.inserts + [close]
    }

    private var identityInsertStyle: IdentityInsertStyle {
        guard plan.insertsIntoIdentityColumn else { return .plain }
        switch targetDatabaseType {
        case .postgresql, .pglite:
            return .overridingSystemValue
        case .mssql:
            return .identityInsertSession
        default:
            return .plain
        }
    }

    private var qualifiedTable: String {
        SchemaQualifiedName.render(
            name: plan.table,
            schema: plan.targetSchema,
            databaseType: targetDatabaseType,
            quote: targetDriver.quoteIdentifier
        )
    }

    private func literal(_ value: PluginCellValue, column: String) -> String {
        CompareSQLLiteral.literal(
            for: value,
            columnType: targetTypes[column.lowercased()],
            databaseType: targetDatabaseType,
            driver: targetDriver
        )
    }

    private func insertStatement(row: DataRow, entry: RowDiffEntry) -> SyncStatement {
        let columns = plan.writeColumns
        let columnList = columns.map { targetDriver.quoteIdentifier($0) }.joined(separator: ", ")
        let valueList = columns.map { literal(row.value(for: $0), column: $0) }.joined(separator: ", ")
        let override = identityInsertStyle == .overridingSystemValue ? " OVERRIDING SYSTEM VALUE" : ""
        return SyncStatement(
            sql: "INSERT INTO \(qualifiedTable) (\(columnList))\(override) VALUES (\(valueList))",
            objectName: plan.id,
            summary: String(format: String(localized: "Insert row %@ into %@"), entry.keyDescription, plan.table),
            expectedRowCount: 1
        )
    }

    private func updateStatement(source: DataRow, target: DataRow, entry: RowDiffEntry) -> SyncStatement? {
        let updatable = plan.updatableColumns
        let changedKeys = updatable.filter { plan.isKeyColumn($0) && entry.differs(in: $0) }
        let assignable = updatable.filter { !plan.isKeyColumn($0) } + changedKeys
        guard !assignable.isEmpty, let predicate = keyPredicate(row: target) else { return nil }
        let assignments = assignable
            .map { "\(targetDriver.quoteIdentifier($0)) = \(literal(source.value(for: $0), column: $0))" }
            .joined(separator: ", ")
        return SyncStatement(
            sql: "UPDATE \(qualifiedTable) SET \(assignments) WHERE \(predicate)",
            objectName: plan.id,
            summary: String(format: String(localized: "Update row %@ in %@"), entry.keyDescription, plan.table),
            expectedRowCount: 1
        )
    }

    private func deleteStatement(row: DataRow, entry: RowDiffEntry) -> SyncStatement? {
        guard let predicate = keyPredicate(row: row) else { return nil }
        return SyncStatement(
            sql: "DELETE FROM \(qualifiedTable) WHERE \(predicate)",
            objectName: plan.id,
            summary: String(format: String(localized: "Delete row %@ from %@"), entry.keyDescription, plan.table),
            hazards: [SyncHazard(
                kind: .dataLoss,
                severity: .refusedByDefault,
                explanation: String(
                    format: String(localized: "Deleting row %@ from %@ permanently removes it."),
                    entry.keyDescription, plan.table
                )
            )],
            expectedRowCount: 1
        )
    }

    private func keyPredicate(row: DataRow) -> String? {
        guard !plan.keyColumns.isEmpty else { return nil }
        return plan.keyColumns
            .map { column -> String in
                let quoted = targetDriver.quoteIdentifier(column)
                let value = row.value(for: column)
                if case .null = value { return "\(quoted) IS NULL" }
                return "\(quoted) = \(literal(value, column: column))"
            }
            .joined(separator: " AND ")
    }
}
