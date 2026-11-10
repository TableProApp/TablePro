//
//  QueryResult+Masking.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension QueryResult {
    func masked(by policy: MaskingPolicy, table: String? = nil) -> QueryResult {
        guard !policy.isEmpty else { return self }
        let masks = policy.columnMasks(table: table, columns: columns, columnTypes: columnTypes)
        return masked(by: masks, policy: policy, table: table)
    }

    // For MCP, the assistant and scripts: matched by what each column reads, not by what the statement named it.
    func maskedForExternalCaller(by policy: MaskingPolicy, table: String? = nil) -> QueryResult {
        guard !policy.isEmpty else { return self }
        let masks = policy.externalColumnMasks(
            table: table, columns: columns, typeNames: columnTypes.map(\.rawType), origins: columnOrigins
        )
        var result = masked(by: masks, policy: policy, table: table)
        let untraced = policy.untracedColumns(table: table, columns: columns, origins: columnOrigins)
        if !rows.isEmpty, let note = Self.untracedNote(untraced.map { columns[$0] }, columnCount: columns.count) {
            result.statusMessage = [statusMessage, note].compactMap { $0 }.joined(separator: " ")
        }
        return result
    }

    private static func untracedNote(_ names: [String], columnCount: Int) -> String? {
        guard !names.isEmpty else { return nil }
        guard names.count < columnCount else {
            return String(
                localized: "Masked every column: this connection has masking rules, and TablePro could not trace any of them to a table column."
            )
        }
        return String(
            format: String(
                localized: "Masked %@: this connection has masking rules, and TablePro could not trace these columns to a table column."
            ),
            ListFormatter.localizedString(byJoining: names)
        )
    }

    private func masked(by masks: ColumnMasks, policy: MaskingPolicy, table: String?) -> QueryResult {
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
        masked.columnOrigins = columnOrigins
        masked.rowLocators = rowLocators
        masked.serverOutput = serverOutput
        masked.exportDocuments = exportDocuments?.enumerated().map { index, document in
            ExportDocumentMasking.document(
                document, columns: columns, masks: masks, policy: policy, table: table,
                row: rows.indices.contains(index) ? rows[index] : nil
            )
        }
        masked.absentCells = absentCells
        masked.unloadedCells = unloadedCells
        return masked
    }
}

extension PluginQueryResult {
    func masked(by policy: MaskingPolicy, table: String? = nil) -> PluginQueryResult {
        let masks = policy.columnMasks(table: table, columns: columns, typeNames: columnTypeNames)
        guard !policy.isEmpty else { return self }
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
        masked.exportDocuments = exportDocuments?.enumerated().map { index, document in
            ExportDocumentMasking.document(
                document, columns: columns, masks: masks, policy: policy, table: table,
                row: rows.indices.contains(index) ? rows[index] : nil
            )
        }
        masked.absentCells = absentCells
        return masked
    }
}
