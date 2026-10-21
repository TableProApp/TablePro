//
//  UnloadedValuePlan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A deferred column reads its value only up to the limit; its byte length follows in a trailing
// column named after the column's position in the select list.
struct UnloadedValuePlan: Equatable, Sendable {
    let columns: [String]
    let byteLengthFunction: String
    let inlineByteLimit: Int

    // MySQL's BLOB holds at most 64 KB, so a BLOB value always arrives with the page.
    static let defaultInlineByteLimit = 65_536
    static let lengthAliasPrefix = "__tablepro_byte_length_"

    // A value is read back by key, and a sorted or value-filtered column needs its values in the page.
    static func resolve(
        selectedColumns: [String],
        columnTypes: [String: ColumnType],
        primaryKeys: [String],
        sortColumns: [String] = [],
        valueFilteredColumns: [String] = [],
        byteLengthFunction: String?,
        inlineByteLimit: Int
    ) -> UnloadedValuePlan? {
        guard let byteLengthFunction, !byteLengthFunction.isEmpty, !primaryKeys.isEmpty,
              primaryKeys.allSatisfy(selectedColumns.contains) else { return nil }
        let kept = Set(primaryKeys).union(sortColumns).union(valueFilteredColumns)
        let deferred = selectedColumns.filter { columnTypes[$0]?.isBlobType == true && !kept.contains($0) }
        guard !deferred.isEmpty else { return nil }
        return UnloadedValuePlan(
            columns: deferred,
            byteLengthFunction: byteLengthFunction,
            inlineByteLimit: max(0, inlineByteLimit)
        )
    }

    func selectList(for selectColumns: [String], quote: (String) -> String) -> String {
        let deferred = Set(columns)
        var items: [String] = []
        var lengths: [String] = []
        for (index, name) in selectColumns.enumerated() {
            let quoted = quote(name)
            guard deferred.contains(name) else {
                items.append(quoted)
                continue
            }
            let length = "\(byteLengthFunction)(\(quoted))"
            items.append("CASE WHEN \(length) <= \(inlineByteLimit) THEN \(quoted) END AS \(quoted)")
            lengths.append("\(length) AS \(quote(Self.lengthAliasPrefix + String(index)))")
        }
        return (items + lengths).joined(separator: ", ")
    }

    func lengthColumns(for selectColumns: [String]) -> [String] {
        let deferred = Set(columns)
        return selectColumns.enumerated()
            .filter { deferred.contains($0.element) }
            .map { Self.lengthAliasPrefix + String($0.offset) }
    }
}

struct UnloadedValueFold {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[PluginCellValue]]
    let columnMeta: [ResultColumnMeta]?
    let unloadedCells: [Int: [Int: Int]]

    // Only the length columns the page's plan asked for, so a table's own column of that name stays.
    static func fold(
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[PluginCellValue]],
        columnMeta: [ResultColumnMeta]?,
        lengthColumns: [String]
    ) -> UnloadedValueFold? {
        guard !lengthColumns.isEmpty, columns.count > lengthColumns.count,
              Array(columns.suffix(lengthColumns.count)) == lengthColumns else { return nil }
        let start = columns.count - lengthColumns.count
        let targets = lengthColumns.compactMap(measuredColumn(named:))
        guard targets.count == lengthColumns.count, targets.allSatisfy({ $0 >= 0 && $0 < start }) else { return nil }

        var unloaded: [Int: [Int: Int]] = [:]
        var stripped: [[PluginCellValue]] = []
        stripped.reserveCapacity(rows.count)
        for (rowIndex, row) in rows.enumerated() {
            for (offset, target) in targets.enumerated() {
                let lengthIndex = start + offset
                guard lengthIndex < row.count, target < row.count, row[target].isNull,
                      let length = byteLength(row[lengthIndex]) else { continue }
                unloaded[rowIndex, default: [:]][target] = length
            }
            stripped.append(row.count > start ? Array(row.prefix(start)) : row)
        }
        return UnloadedValueFold(
            columns: Array(columns.prefix(start)),
            columnTypes: Array(columnTypes.prefix(start)),
            rows: stripped,
            columnMeta: columnMeta.map { Array($0.prefix(start)) },
            unloadedCells: unloaded
        )
    }

    private static func measuredColumn(named name: String) -> Int? {
        guard name.hasPrefix(UnloadedValuePlan.lengthAliasPrefix) else { return nil }
        return Int(name.dropFirst(UnloadedValuePlan.lengthAliasPrefix.count))
    }

    private static func byteLength(_ cell: PluginCellValue) -> Int? {
        switch cell {
        case .null: return nil
        case .text(let text): return Int(text)
        case .bytes(let data): return String(bytes: data, encoding: .utf8).flatMap { Int($0) }
        }
    }
}

extension QueryResult {
    func foldingUnloadedValues(lengthColumns: [String]) -> QueryResult {
        guard let fold = UnloadedValueFold.fold(
            columns: columns, columnTypes: columnTypes, rows: rows, columnMeta: columnMeta,
            lengthColumns: lengthColumns
        ) else { return self }
        var folded = QueryResult(
            columns: fold.columns,
            columnTypes: fold.columnTypes,
            rows: fold.rows,
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            error: error,
            timing: timing,
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: fold.columnMeta,
            rowLocators: rowLocators,
            serverOutput: serverOutput,
            absentCells: absentCells
        )
        folded.unloadedCells = fold.unloadedCells
        return folded
    }
}

extension QueryFetchResult {
    func foldingUnloadedValues(lengthColumns: [String]) -> QueryFetchResult {
        guard let fold = UnloadedValueFold.fold(
            columns: columns, columnTypes: columnTypes, rows: rows, columnMeta: resultColumnMeta,
            lengthColumns: lengthColumns
        ) else { return self }
        var folded = QueryFetchResult(
            columns: fold.columns,
            columnTypes: fold.columnTypes,
            rows: fold.rows,
            executionTime: executionTime,
            rowsAffected: rowsAffected,
            statusMessage: statusMessage,
            isTruncated: isTruncated,
            resultColumnMeta: fold.columnMeta,
            timing: timing,
            serverOutput: serverOutput,
            rowLocators: rowLocators,
            absentCells: absentCells
        )
        folded.unloadedCells = fold.unloadedCells
        return folded
    }
}
