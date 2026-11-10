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
    private let targetDriver: any PluginDatabaseDriver
    private let targetDatabaseType: DatabaseType
    private let options: DataCompareOptions
    private let plan: DataComparePlan
    private let targetTypes: [String: ColumnType]
    // Bit strings the two sides spell differently, so a source value is respelled before it is written.
    private let bitRespellings: [String: (pair: CrossEngineValueCoercer.ColumnPair, from: SQLTypeFamily)]
    private let immutableColumns: Set<String>

    internal init(
        targetDriver: any PluginDatabaseDriver,
        targetDatabaseType: DatabaseType,
        options: DataCompareOptions,
        plan: DataComparePlan,
        immutableColumns: Set<String> = []
    ) {
        self.targetDriver = targetDriver
        self.targetDatabaseType = targetDatabaseType
        self.options = options
        self.plan = plan
        self.immutableColumns = Set(immutableColumns.map { $0.lowercased() })
        var types: [String: ColumnType] = [:]
        var respellings: [String: (pair: CrossEngineValueCoercer.ColumnPair, from: SQLTypeFamily)] = [:]
        for column in plan.columns {
            if let respelling = Self.bitRespelling(of: column, targetDatabaseType: targetDatabaseType) {
                respellings[column.name.lowercased()] = respelling
            }
            guard let type = column.targetColumnType else { continue }
            types[column.name.lowercased()] = type
        }
        self.targetTypes = types
        self.bitRespellings = respellings
    }

    private static func bitRespelling(
        of column: CompareColumn,
        targetDatabaseType: DatabaseType
    ) -> (pair: CrossEngineValueCoercer.ColumnPair, from: SQLTypeFamily)? {
        guard let sourceFamily = column.sourceFamily, let sourceType = column.sourceType else { return nil }
        let targetFamily = column.targetFamily ?? SQLTypeFamily.of(targetDatabaseType)
        let pair = CrossEngineValueCoercer.ColumnPair(
            source: SQLTypeParser.parse(sourceType, family: sourceFamily).kind,
            target: SQLTypeParser.parse(column.targetType ?? sourceType, family: targetFamily).kind
        )
        guard CrossEngineValueCoercer.respellsBits(pair, from: sourceFamily, to: targetFamily) else { return nil }
        return (pair, sourceFamily)
    }

    // A value read from the source, which the target may spell differently.
    private func sourceLiteral(_ value: PluginCellValue, column: String) -> String {
        guard let respelling = bitRespellings[column.lowercased()] else { return literal(value, column: column) }
        let respelled = CrossEngineValueCoercer.respelledBits(value, pair: respelling.pair, from: respelling.from)
        return literal(respelled, column: column)
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
        let session = ExplicitIdentityInsert.sessionStatements(for: table)
        let closingSQL = session.close
        let open = SyncStatement(
            sql: session.open,
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

    private var identityInsertStyle: ExplicitIdentityInsert? {
        guard plan.insertsIntoIdentityColumn else { return nil }
        return ExplicitIdentityInsert.style(for: targetDatabaseType)
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
        let valueList = columns.map { sourceLiteral(row.value(for: $0), column: $0) }.joined(separator: ", ")
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
        // The target refuses any assignment of an immutable column, so only a differing one is sent, to be refused.
        let assignable = updatable.filter {
            !plan.isKeyColumn($0) && (!immutableColumns.contains($0.lowercased()) || entry.differs(in: $0))
        } + changedKeys
        guard !assignable.isEmpty, let predicate = keyPredicate(row: target) else { return nil }
        let assignments = assignable
            .map { "\(targetDriver.quoteIdentifier($0)) = \(sourceLiteral(source.value(for: $0), column: $0))" }
            .joined(separator: ", ")
        let table = qualifiedTable
        return SyncStatement(
            sql: targetDriver.rowUpdateStatement(table: table, assignments: assignments, predicate: predicate)
                ?? "UPDATE \(table) SET \(assignments) WHERE \(predicate)",
            objectName: plan.id,
            summary: String(format: String(localized: "Update row %@ in %@"), entry.keyDescription, plan.table),
            expectedRowCount: 1
        )
    }

    private func deleteStatement(row: DataRow, entry: RowDiffEntry) -> SyncStatement? {
        guard let predicate = keyPredicate(row: row) else { return nil }
        let table = qualifiedTable
        return SyncStatement(
            sql: targetDriver.rowDeleteStatement(table: table, predicate: predicate)
                ?? "DELETE FROM \(table) WHERE \(predicate)",
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
