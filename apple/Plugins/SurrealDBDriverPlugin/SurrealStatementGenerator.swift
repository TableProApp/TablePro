//
//  SurrealStatementGenerator.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

public enum SurrealStatementGenerator {
    public static func rowWrites(
        table: String,
        scope: SurrealScope,
        columns: [String],
        kinds: [String: SurrealFieldKind],
        heldKinds: [String: Set<SurrealFieldKind.Base>] = [:],
        recordKinds: [String: [String: SurrealFieldKind.Base]] = [:],
        declaredKinds: [String: SurrealFieldKind] = [:],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws(PluginRowWriteRefusal) -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        var insertedWritten: Set<Int> = []
        let typing = FieldTyping(kinds: kinds, held: heldKinds, records: recordKinds, declared: declaredKinds)

        var defaults: [Int: Set<Int>] = [:]
        for change in changes where change.type == .insert {
            defaults[change.rowIndex, default: []].formUnion(change.defaultColumns ?? [])
        }

        // In the order received, which is edit order: a record deleted to free a unique value goes before the one taking it.
        for change in changes {
            let index = change.rowIndex
            if insertedRowIndices.contains(index) {
                guard insertedWritten.insert(index).inserted, let values = insertedRowData[index] else { continue }
                writes.append(try insert(
                    table: table, scope: scope, columns: columns, typing: typing, values: values,
                    defaults: defaults[index] ?? [], rowIndex: index
                ))
                continue
            }
            if change.type == .update,
               let write = try update(table: table, scope: scope, columns: columns, typing: typing, change: change) {
                writes.append(write)
            }
            if change.type == .delete || deletedRowIndices.contains(index),
               let write = delete(table: table, scope: scope, columns: columns, change: change) {
                writes.append(write)
            }
        }

        return writes
    }

    private struct FieldTyping {
        let kinds: [String: SurrealFieldKind]
        let held: [String: Set<SurrealFieldKind.Base>]
        // Keyed by record literal, the text the grid shows in the id column.
        let records: [String: [String: SurrealFieldKind.Base]]
        let declared: [String: SurrealFieldKind]

        // A single declared type decides: SurrealDB leaves rows written before `DEFINE FIELD ... TYPE` as
        // they were, and rejects another kind written into the field now.
        func value(of cell: PluginCellValue, in column: String, record: String? = nil) -> SurrealValue {
            let recordHeld = Self.declaresOneKind(declared[column]) ? nil : record.flatMap { records[$0]?[column] }
            return SurrealCellCoder.value(
                from: cell,
                kind: declared[column] ?? kinds[column],
                held: held[column] ?? [],
                recordHeld: recordHeld
            )
        }

        private static func declaresOneKind(_ kind: SurrealFieldKind?) -> Bool {
            guard let kind, kind.base != .any else { return false }
            let concrete = kind.raw.split(separator: "|").filter { alternative in
                let name = alternative.trimmingCharacters(in: .whitespaces).lowercased()
                return name != "none" && name != "null"
            }
            return concrete.count <= 1
        }
    }

    // MARK: - Statements

    private static func update(
        table: String,
        scope: SurrealScope,
        columns: [String],
        typing: FieldTyping,
        change: PluginRowChange
    ) throws(PluginRowWriteRefusal) -> PluginRowWrite? {
        if let reserved = change.cellChanges.first(where: { SurrealInfoParser.isReservedColumn($0.columnName) }) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: reservedColumnReason(reserved.columnName))
        }
        let recordKey = Self.recordText(columns: columns, originalRow: change.originalRow)
        guard let record = recordKey.flatMap({ SurrealQL.parseRecordId($0, fallbackTable: table) }) else { return nil }
        let editable = change.cellChanges.filter { !change.isColumnDefault($0.columnIndex) }
        guard !editable.isEmpty else { return nil }

        var parameters: [PluginCellValue] = [SurrealCellCoder.parameter(.recordId(record))]
        var assignments: [String] = []

        for cell in editable {
            try refuseShortened(cell.newValue, in: cell.columnName, rowIndex: change.rowIndex)
            if !cell.newValue.isNull {
                try refuseShortened(cell.oldValue, in: cell.columnName, rowIndex: change.rowIndex)
            }
            let value = typing.value(of: cell.newValue, in: cell.columnName, record: recordKey)
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
        typing: FieldTyping,
        values: [PluginCellValue],
        defaults: Set<Int>,
        rowIndex: Int
    ) throws(PluginRowWriteRefusal) -> PluginRowWrite {
        var parameters: [PluginCellValue] = []
        var assignments: [String] = []
        var target = SurrealQL.quoteIdentifier(table)

        for (index, column) in columns.enumerated() {
            guard index < values.count, !defaults.contains(index) else { continue }
            let cell = values[index]

            if column == SurrealInfoParser.recordIdColumn {
                guard case let .text(text) = cell else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let record = SurrealQL.parseRecordId(text, fallbackTable: table) else { continue }
                parameters.append(SurrealCellCoder.parameter(.recordId(record)))
                target = "$p\(parameters.count - 1)"
                continue
            }

            if case .null = cell { continue }
            try refuseShortened(cell, in: column, rowIndex: rowIndex)
            let value = typing.value(of: cell, in: column)
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

    private static func refuseShortened(_ cell: PluginCellValue, in column: String, rowIndex: Int) throws(PluginRowWriteRefusal) {
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

    private static func reservedColumnReason(_ column: String) -> String {
        guard column != SurrealInfoParser.recordIdColumn else {
            return String(localized: "A record's id cannot be edited.")
        }
        let format = String(
            localized: "'%@' cannot be saved from the grid. SurrealDB ignores it on a relation, so delete the relation and RELATE it again. Otherwise, UPDATE it in the editor."
        )
        return String(format: format, column)
    }

    private static func recordId(
        table: String,
        columns: [String],
        originalRow: [PluginCellValue]?
    ) -> SurrealRecordID? {
        recordText(columns: columns, originalRow: originalRow).flatMap {
            SurrealQL.parseRecordId($0, fallbackTable: table)
        }
    }

    private static func recordText(columns: [String], originalRow: [PluginCellValue]?) -> String? {
        guard let originalRow,
              let index = columns.firstIndex(of: SurrealInfoParser.recordIdColumn),
              index < originalRow.count,
              case let .text(text) = originalRow[index] else { return nil }
        return text
    }
}
