//
//  SurrealStatementGenerator.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

public enum SurrealStatementGenerator {
    static let autoIdMarker = "__DEFAULT__"

    static func isAutoDefault(_ value: PluginCellValue) -> Bool {
        guard case let .text(text) = value else { return false }
        return text.trimmingCharacters(in: .whitespaces) == autoIdMarker
    }

    public static func rowWrites(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []

        for change in changes where change.type == .update && !insertedRowIndices.contains(change.rowIndex) {
            guard let write = try update(table: table, scope: scope, columns: columns, kinds: kinds, change: change) else {
                continue
            }
            writes.append(write)
        }

        for index in insertedRowIndices.sorted() {
            guard let values = insertedRowData[index] else { continue }
            writes.append(try insert(
                table: table, scope: scope, columns: columns, kinds: kinds, values: values, rowIndex: index
            ))
        }

        for change in changes where change.type == .delete || deletedRowIndices.contains(change.rowIndex) {
            guard !insertedRowIndices.contains(change.rowIndex) else { continue }
            guard let write = delete(table: table, scope: scope, columns: columns, change: change) else { continue }
            writes.append(write)
        }

        return writes
    }

    // MARK: - Statements

    private static func update(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        change: PluginRowChange
    ) throws -> PluginRowWrite? {
        guard let record = recordId(table: table, columns: columns, originalRow: change.originalRow) else { return nil }
        let editable = change.cellChanges.filter {
            !SurrealInfoParser.isReservedColumn($0.columnName) && !Self.isAutoDefault($0.newValue)
        }
        guard !editable.isEmpty else { return nil }

        var parameters: [PluginCellValue] = [SurrealCellCoder.parameter(.recordId(record))]
        var assignments: [String] = []

        for cell in editable {
            try refuseShortened(cell.newValue, in: cell.columnName, rowIndex: change.rowIndex)
            if !cell.newValue.isNull {
                try refuseShortened(cell.oldValue, in: cell.columnName, rowIndex: change.rowIndex)
            }
            let value = SurrealCellCoder.value(from: cell.newValue, kind: kinds[cell.columnName])
            parameters.append(SurrealCellCoder.parameter(value))
            assignments.append(SurrealQL.quoteIdentifier(cell.columnName) + " = $p\(parameters.count - 1)")
        }

        let statement = "UPDATE $p0 SET " + assignments.joined(separator: ", ") + ";"
        return PluginRowWrite(
            statement: SurrealQueryBuilder.compose(scope: scope, statement: statement),
            parameters: parameters,
            rowIndices: [change.rowIndex]
        )
    }

    private static func insert(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        values: [PluginCellValue],
        rowIndex: Int
    ) throws -> PluginRowWrite {
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
            try refuseShortened(cell, in: column, rowIndex: rowIndex)
            let value = SurrealCellCoder.value(from: cell, kind: kinds[column])
            parameters.append(SurrealCellCoder.parameter(value))
            assignments.append(SurrealQL.quoteIdentifier(column) + " = $p\(parameters.count - 1)")
        }

        let statement = assignments.isEmpty
            ? "CREATE \(target);"
            : "CREATE \(target) SET " + assignments.joined(separator: ", ") + ";"
        return PluginRowWrite(
            statement: SurrealQueryBuilder.compose(scope: scope, statement: statement),
            parameters: parameters,
            rowIndices: [rowIndex]
        )
    }

    private static func delete(
        table: String,
        scope: SurrealScope,
        columns: [String],
        change: PluginRowChange
    ) -> PluginRowWrite? {
        guard let record = recordId(table: table, columns: columns, originalRow: change.originalRow) else { return nil }
        return PluginRowWrite(
            statement: SurrealQueryBuilder.compose(scope: scope, statement: "DELETE $p0;"),
            parameters: [SurrealCellCoder.parameter(.recordId(record))],
            rowIndices: [change.rowIndex]
        )
    }

    // MARK: - Refusals

    private static func refuseShortened(_ cell: PluginCellValue, in column: String, rowIndex: Int) throws {
        guard case let .text(text) = cell, JSONTruncation.isIncompleteStructure(text) else { return }
        throw PluginRowWriteRefusal(
            rowIndex: rowIndex,
            reason: String(
                format: String(
                    localized: "The value in %@ is shortened for display, so saving it would store only the part shown. Change this field with a query."
                ),
                column
            )
        )
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
