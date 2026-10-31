import Foundation
import TableProPluginKit
import TableProTeradataCore

extension TeradataPluginDriver {
    func sqlLiteral(_ value: PluginCellValue) -> String {
        TeradataRowEditSQL.literal(value)
    }

    func generateStatements(
        table: String, columns: [String], primaryKeyColumns: [String],
        changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateStatements(
            table: table, schema: nil, columns: columns, primaryKeyColumns: primaryKeyColumns,
            changes: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices)
    }

    func generateStatements(
        table: String, schema: String?, columns: [String], primaryKeyColumns: [String],
        changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let target = TeradataSchemaQueries.qualifiedName(
            database: effectiveDatabaseForSchema(schema), table: table)
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex], values.count == columns.count else { continue }
                let insert = TeradataRowEditSQL.insert(
                    target: target,
                    columns: columns,
                    values: values,
                    expressionColumns: change.expressionColumns ?? []
                )
                statements.append((insert, []))
            case .update:
                let expressionColumns = change.expressionColumns ?? []
                let assignments = change.cellChanges.map {
                    TeradataRowEditSQL.assignment(
                        column: $0.columnName,
                        value: $0.newValue,
                        isExpression: expressionColumns.contains($0.columnIndex)
                    )
                }
                guard !assignments.isEmpty,
                      let whereClause = keyPredicate(primaryKeyColumns, columns: columns, change: change)
                else { continue }
                statements.append(("UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause)", []))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex),
                      let whereClause = keyPredicate(primaryKeyColumns, columns: columns, change: change)
                else { continue }
                statements.append(("DELETE FROM \(target) WHERE \(whereClause)", []))
            }
        }
        return statements.isEmpty ? nil : statements
    }

    func generateIdentityPreservingInsert(
        table: String, schema: String?, columns: [String], primaryKeyColumns: [String], rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let target = TeradataSchemaQueries.qualifiedName(database: effectiveDatabaseForSchema(schema), table: table)
        return rows.map { (TeradataRowEditSQL.insert(target: target, columns: columns, values: $0), []) }
    }

    private func quote(_ name: String) -> String {
        TeradataSchemaQueries.quoteIdentifier(name)
    }

    private func effectiveDatabaseForSchema(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        return currentDatabaseName
    }

    private func keyPredicate(_ primaryKeyColumns: [String], columns: [String], change: PluginRowChange) -> String? {
        let keyColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        var conditions: [String] = []
        for column in keyColumns {
            // A value that was never loaded is not NULL, and matching it as one finds the wrong rows.
            guard let value = oldValue(for: column, columns: columns, change: change) else { return nil }
            if case .null = value {
                conditions.append("\(quote(column)) IS NULL")
            } else {
                conditions.append("\(quote(column)) = \(sqlLiteral(value))")
            }
        }
        return conditions.isEmpty ? nil : conditions.joined(separator: " AND ")
    }

    private func oldValue(for column: String, columns: [String], change: PluginRowChange) -> PluginCellValue? {
        if let originalRow = change.originalRow,
           let index = columns.firstIndex(of: column), index < originalRow.count {
            return originalRow[index]
        }
        return change.cellChanges.first(where: { $0.columnName == column })?.oldValue
    }
}
