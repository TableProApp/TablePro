//
//  SurrealStatementGenerator.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

public typealias SurrealStatement = (statement: String, parameters: [PluginCellValue])

public enum SurrealStatementGenerator {
    static let autoIdMarker = "__DEFAULT__"

    static func isAutoDefault(_ value: PluginCellValue) -> Bool {
        guard case let .text(text) = value else { return false }
        return text.trimmingCharacters(in: .whitespaces) == autoIdMarker
    }

    public static func statements(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [SurrealStatement] {
        var statements: [SurrealStatement] = []

        for change in changes where change.type == .update && !insertedRowIndices.contains(change.rowIndex) {
            guard let statement = update(table: table, scope: scope, columns: columns, kinds: kinds, change: change) else {
                continue
            }
            statements.append(statement)
        }

        for index in insertedRowIndices.sorted() {
            guard let values = insertedRowData[index] else { continue }
            guard let statement = insert(table: table, scope: scope, columns: columns, kinds: kinds, values: values) else {
                continue
            }
            statements.append(statement)
        }

        for change in changes where change.type == .delete || deletedRowIndices.contains(change.rowIndex) {
            guard !insertedRowIndices.contains(change.rowIndex) else { continue }
            guard let statement = delete(table: table, scope: scope, columns: columns, change: change) else { continue }
            statements.append(statement)
        }

        return statements
    }

    // MARK: - Statements

    private static func update(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        change: PluginRowChange
    ) -> SurrealStatement? {
        guard let record = recordId(table: table, columns: columns, originalRow: change.originalRow) else { return nil }
        let editable = change.cellChanges.filter {
            !SurrealInfoParser.isReservedColumn($0.columnName) && !Self.isAutoDefault($0.newValue)
        }
        guard !editable.isEmpty else { return nil }

        var parameters: [PluginCellValue] = [SurrealCellCoder.parameter(.recordId(record))]
        var assignments: [String] = []

        for cell in editable {
            let value = SurrealCellCoder.value(from: cell.newValue, kind: kinds[cell.columnName])
            parameters.append(SurrealCellCoder.parameter(value))
            assignments.append(SurrealQL.quoteIdentifier(cell.columnName) + " = $p\(parameters.count - 1)")
        }

        let statement = "UPDATE $p0 SET " + assignments.joined(separator: ", ") + ";"
        return (SurrealQueryBuilder.compose(scope: scope, statement: statement), parameters)
    }

    private static func insert(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        values: [PluginCellValue]
    ) -> SurrealStatement? {
        var parameters: [PluginCellValue] = []
        var assignments: [String] = []
        var target = SurrealQL.quoteIdentifier(table)

        for (index, column) in columns.enumerated() {
            guard index < values.count else { continue }
            let cell = values[index]

            if column == SurrealInfoParser.recordIdColumn {
                guard case let .text(text) = cell else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != Self.autoIdMarker else { continue }
                guard let record = SurrealQL.parseRecordId(text, fallbackTable: table) else { continue }
                parameters.append(SurrealCellCoder.parameter(.recordId(record)))
                target = "$p\(parameters.count - 1)"
                continue
            }

            if case .null = cell { continue }
            if Self.isAutoDefault(cell) { continue }
            let value = SurrealCellCoder.value(from: cell, kind: kinds[column])
            parameters.append(SurrealCellCoder.parameter(value))
            assignments.append(SurrealQL.quoteIdentifier(column) + " = $p\(parameters.count - 1)")
        }

        let statement = assignments.isEmpty
            ? "CREATE \(target);"
            : "CREATE \(target) SET " + assignments.joined(separator: ", ") + ";"
        return (SurrealQueryBuilder.compose(scope: scope, statement: statement), parameters)
    }

    private static func delete(
        table: String,
        scope: SurrealScope,
        columns: [String],
        change: PluginRowChange
    ) -> SurrealStatement? {
        guard let record = recordId(table: table, columns: columns, originalRow: change.originalRow) else { return nil }
        let parameters = [SurrealCellCoder.parameter(.recordId(record))]
        return (SurrealQueryBuilder.compose(scope: scope, statement: "DELETE $p0;"), parameters)
    }

    // MARK: - Helpers

    private static func recordId(
        table: String,
        columns: [String],
        originalRow: [PluginCellValue]?
    ) -> SurrealRecordID? {
        guard let originalRow,
              let index = columns.firstIndex(of: SurrealInfoParser.recordIdColumn),
              index < originalRow.count,
              case let .text(text) = originalRow[index] else { return nil }
        return SurrealQL.parseRecordId(text, fallbackTable: table)
    }
}
