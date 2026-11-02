//
//  QueryResult+Masking.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension QueryResult {
    func masked(by policy: MaskingPolicy, table: String? = nil) -> QueryResult {
        let masks = policy.columnMasks(table: table, columns: columns, columnTypes: columnTypes)
        guard !masks.isEmpty else { return self }
        var masked = QueryResult(
            columns: columns,
            columnTypes: columnTypes,
            rows: masks.rows(rows),
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            error: error
        )
        masked.timing = timing
        masked.isTruncated = isTruncated
        masked.statusMessage = statusMessage
        masked.columnMeta = columnMeta
        masked.rowLocators = rowLocators
        masked.serverOutput = serverOutput
        masked.absentCells = absentCells
        masked.unloadedCells = unloadedCells
        return masked
    }
}

extension PluginQueryResult {
    func masked(by policy: MaskingPolicy, table: String? = nil) -> PluginQueryResult {
        let masks = policy.columnMasks(table: table, columns: columns, typeNames: columnTypeNames)
        guard !masks.isEmpty else { return self }
        var masked = PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: masks.rows(rows),
            rowsAffected: rowsAffected,
            timing: timing,
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: columnMeta
        )
        masked.rowLocators = rowLocators
        masked.absentCells = absentCells
        return masked
    }
}
