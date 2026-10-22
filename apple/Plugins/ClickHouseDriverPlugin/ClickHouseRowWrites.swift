//
//  ClickHouseRowWrites.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

// A ClickHouse row has no key that names it: the primary key is the sorting key and repeats. An update or delete
// matches every value the grid loaded, a lookup right before it has to find exactly that many rows, and the write is
// pinned to the parts they were found in, so a row inserted after the lookup is never reached. Measured on 25.8.
// `_part_offset` would pin one row of a part, but a mutation filtering on it fails and stays queued before 25
// (measured on 24.8: "Virtual column _part_offset must be filled by range reader").
nonisolated enum ClickHouseRowWrites {
    struct Forms {
        let update: (_ table: String, _ assignments: String, _ predicate: String) -> String
        let delete: (_ table: String, _ predicate: String) -> String
    }

    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    static func writes(
        table: String,
        schema: String?,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext,
        forms: Forms
    ) throws -> [PluginRowWrite] {
        let target = qualified(table: table, schema: schema)
        let matcher = RowMatcher(columns: columns, context: context)
        var writes: [PluginRowWrite] = []
        // Deletes group only within a run, so a row deleted and then inserted again keeps that order.
        var deleteGroups: [(row: [PluginCellValue], key: [ExactCell], indices: [Int])] = []
        func flushDeletes() throws {
            for group in deleteGroups {
                writes.append(try delete(group.row, rowIndices: group.indices, target: target, matcher: matcher, forms: forms))
            }
            deleteGroups = []
        }

        for change in changes {
            if change.type != .delete {
                try flushDeletes()
            }
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex] else { continue }
                writes.append(insert(
                    into: target, columns: columns, values: values, expressions: change.expressionColumns ?? [],
                    serverOwned: context.serverOwnedColumns, rowIndex: change.rowIndex
                ))
            case .update:
                guard !change.cellChanges.isEmpty else { continue }
                writes.append(try update(change, target: target, matcher: matcher, forms: forms))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                let row = try matcher.loadedRow(of: change)
                let key = row.map(ExactCell.init)
                if let group = deleteGroups.firstIndex(where: { $0.key == key }) {
                    deleteGroups[group].indices.append(change.rowIndex)
                } else {
                    deleteGroups.append((row, key, [change.rowIndex]))
                }
            }
        }

        try flushDeletes()
        return writes
    }

    static func insert(
        into target: String,
        columns: [String],
        values: [PluginCellValue],
        expressions: Set<Int>,
        serverOwned: Set<String> = [],
        rowIndex: Int
    ) -> PluginRowWrite {
        var names: [String] = []
        var placeholders: [String] = []
        var parameters: [PluginCellValue] = []
        for (index, value) in values.enumerated() where index < columns.count && value != defaultMarker {
            names.append(clickHouseQuotedIdentifier(columns[index]))
            if expressions.contains(index), case .text(let sql) = value {
                placeholders.append(sql)
            } else {
                placeholders.append("?")
                parameters.append(value)
            }
        }
        // ClickHouse refuses a MATERIALIZED or ALIAS column in an INSERT, even given DEFAULT.
        if names.isEmpty, let first = columns.first(where: { !serverOwned.contains($0) }) {
            names = [clickHouseQuotedIdentifier(first)]
            placeholders = ["DEFAULT"]
        }
        return PluginRowWrite(
            statement: "INSERT INTO \(target) (\(names.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))",
            parameters: parameters,
            rowIndices: [rowIndex]
        )
    }

    private static func update(
        _ change: PluginRowChange,
        target: String,
        matcher: RowMatcher,
        forms: Forms
    ) throws -> PluginRowWrite {
        let row = try matcher.loadedRow(of: change)
        let expressions = change.expressionColumns ?? []
        var assignments: [String] = []
        var assigned: [PluginCellValue] = []
        var landed: [String] = []
        var landedParameters: [PluginCellValue] = []
        for cell in change.cellChanges {
            let column = clickHouseQuotedIdentifier(cell.columnName)
            if expressions.contains(cell.columnIndex), case .text(let sql) = cell.newValue {
                assignments.append("\(column) = \(sql)")
                landed.append("\(column) = \(sql)")
                continue
            }
            assignments.append("\(column) = ?")
            assigned.append(cell.newValue)
            if cell.newValue.isNull {
                landed.append("\(column) IS NULL")
            } else {
                landed.append(matcher.storedMatch(of: cell.columnName))
                landedParameters.append(cell.newValue)
            }
        }

        let match = try matcher.predicate(for: row, rowIndex: change.rowIndex)
        let statement = forms.update(target, assignments.joined(separator: ", "), "\(match.sql) AND _part IN (?)")
        return PluginRowWrite(
            statement: statement,
            parameters: assigned + match.parameters,
            rowIndices: [change.rowIndex],
            lookup: PluginRowLookup(
                query: "SELECT _part FROM \(target) WHERE \(match.sql) LIMIT 2",
                parameters: match.parameters,
                rowCount: 1,
                pinsRows: true,
                check: "SELECT 1 FROM \(target) WHERE \(match.sql) AND NOT ifNull(\(landed.joined(separator: " AND ")), 0) LIMIT 1",
                checkParameters: match.parameters + landedParameters
            )
        )
    }

    // Rows holding the same values cannot be told apart, so deleting all of them is the one exact delete they allow.
    private static func delete(
        _ row: [PluginCellValue],
        rowIndices: [Int],
        target: String,
        matcher: RowMatcher,
        forms: Forms
    ) throws -> PluginRowWrite {
        let match = try matcher.predicate(for: row, rowIndex: rowIndices[0])
        let parts = Array(repeating: "?", count: rowIndices.count).joined(separator: ", ")
        return PluginRowWrite(
            statement: forms.delete(target, "\(match.sql) AND _part IN (\(parts))"),
            parameters: match.parameters,
            rowIndices: rowIndices,
            lookup: PluginRowLookup(
                query: "SELECT _part FROM \(target) WHERE \(match.sql) LIMIT \(rowIndices.count + 1)",
                parameters: match.parameters,
                rowCount: rowIndices.count,
                pinsRows: true,
                check: "SELECT 1 FROM \(target) WHERE \(match.sql) LIMIT 1",
                checkParameters: match.parameters
            )
        )
    }

    // Swift's String equality is canonical, so "é" and "e\u{301}" are equal here and different rows to ClickHouse.
    enum ExactCell: Equatable {
        case null
        case text([UInt8])
        case bytes(Data)

        init(_ value: PluginCellValue) {
            switch value {
            case .null: self = .null
            case .text(let text): self = .text(Array(text.utf8))
            case .bytes(let data): self = .bytes(data)
            }
        }
    }

    static func qualified(table: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return clickHouseQuotedIdentifier(table) }
        return "\(clickHouseQuotedIdentifier(schema)).\(clickHouseQuotedIdentifier(table))"
    }
}

nonisolated extension ClickHouseRowWrites {
    struct RowMatcher {
        let columns: [String]
        let context: PluginRowWriteContext

        func loadedRow(of change: PluginRowChange) throws -> [PluginCellValue] {
            guard let row = change.originalRow, row.count >= columns.count else {
                throw PluginRowWriteRefusal(
                    rowIndex: change.rowIndex,
                    reason: String(localized: "The row's loaded values are missing, so it cannot be found again.")
                )
            }
            return row
        }

        func predicate(for row: [PluginCellValue], rowIndex: Int) throws -> (sql: String, parameters: [PluginCellValue]) {
            var conditions: [String] = []
            var parameters: [PluginCellValue] = []
            // A MATERIALIZED or ALIAS value follows its sources, so an image saved before they changed would match
            // nothing. The lookup still has to find exactly one row without it.
            for (index, column) in columns.enumerated() where !context.serverOwnedColumns.contains(column) {
                if context.rowMatchExcludedColumns.contains(column) || Self.isUncomparable(typeName(of: column)) {
                    throw PluginRowWriteRefusal(
                        rowIndex: rowIndex,
                        reason: String(
                            format: String(localized: "%@ holds values that cannot be compared, so the row cannot be found again."),
                            column
                        )
                    )
                }
                let value = row[index]
                if value.isNull {
                    conditions.append("\(clickHouseQuotedIdentifier(column)) IS NULL")
                } else {
                    conditions.append("\(loadedForm(of: column)) = ?")
                    parameters.append(value)
                }
            }
            guard !conditions.isEmpty else {
                throw PluginRowWriteRefusal(
                    rowIndex: rowIndex,
                    reason: String(localized: "The row has no loaded values to be found by.")
                )
            }
            return (conditions.joined(separator: " AND "), parameters)
        }

        // The grid read every value as the server's text, and a JSON value or a NaN compares equal only as text.
        func loadedForm(of column: String) -> String {
            let quoted = clickHouseQuotedIdentifier(column)
            return Self.matchesAsText(typeName(of: column)) ? "toString(\(quoted))" : quoted
        }

        // The value typed is compared as the column stores it, read by the server: 1.50 is the 1.5 a float holds, NaN
        // the nan it holds, and JSON key order and spacing do not count. A String does not cast to a Map, which
        // compares as typed (measured on 25.8).
        func storedMatch(of column: String) -> String {
            let quoted = clickHouseQuotedIdentifier(column)
            let declared = declaredType(of: column)
            guard !declared.isEmpty, !ClickHousePluginDriver.unwrapTypeWrappers(declared).hasPrefix("Map(") else {
                return "\(quoted) = ?"
            }
            return "toString(\(quoted)) = toString(CAST(? AS \(declared)))"
        }

        private func typeName(of column: String) -> String {
            ClickHousePluginDriver.unwrapTypeWrappers(declaredType(of: column))
        }

        private func declaredType(of column: String) -> String {
            context.columnTypeNames[column]
                ?? context.columnTypeNames.first { $0.key.caseInsensitiveCompare(column) == .orderedSame }?.value
                ?? ""
        }

        static func isUncomparable(_ type: String) -> Bool {
            type.hasPrefix("AggregateFunction(")
        }

        static func matchesAsText(_ type: String) -> Bool {
            isDocument(type) || ["Float32", "Float64", "BFloat16"].contains(type)
        }

        static func isDocument(_ type: String) -> Bool {
            type == "JSON" || type.hasPrefix("JSON(") || type.hasPrefix("Object(") || type == "Dynamic"
                || type.hasPrefix("Dynamic(")
        }
    }
}
