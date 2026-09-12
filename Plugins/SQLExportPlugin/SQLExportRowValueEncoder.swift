//
//  SQLExportRowValueEncoder.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

/// Renders one row of a result as the `(v1, v2, v3)` tuple an `INSERT` carries.
///
/// Built once per table from the stream's header, because everything it needs is a property of the
/// column list rather than of the row: which columns are written at all, which of them hold numbers
/// that may go in unquoted, and how the engine spells a literal. The export used to rebuild all of
/// that for every batch of rows.
///
/// Separate from `SQLExportInsertRenderer`, which owns the statement's prefix and suffix for an
/// insert mode. This owns the rows between them.
internal struct SQLExportRowValueEncoder {
    internal let includedColumnIndices: [Int]

    private let numericIndices: Set<Int>
    private let databaseTypeId: String
    private let escapeStringLiteral: (String) -> String

    internal init(
        columns: [String],
        columnTypeNames: [String],
        excludedColumnNames: Set<String>,
        databaseTypeId: String,
        escapeStringLiteral: @escaping (String) -> String
    ) {
        includedColumnIndices = columns.enumerated().compactMap { index, name in
            excludedColumnNames.contains(name) ? nil : index
        }
        numericIndices = Set(includedColumnIndices.filter { index in
            index < columnTypeNames.count
                && PluginExportUtilities.isNumericColumnType(columnTypeNames[index])
        })
        self.databaseTypeId = databaseTypeId
        self.escapeStringLiteral = escapeStringLiteral
    }

    internal var writesNothing: Bool { includedColumnIndices.isEmpty }

    internal func columnNames(from columns: [String]) -> [String] {
        includedColumnIndices.map { columns[$0] }
    }

    internal func render(_ row: [PluginCellValue]) -> String {
        let values = includedColumnIndices.map { columnIndex -> String in
            guard columnIndex < row.count else { return "NULL" }
            switch row[columnIndex] {
            case .null:
                return "NULL"
            case .bytes(let data):
                return SQLExportBinaryLiteral.render(data, databaseTypeId: databaseTypeId)
            case .text(let value):
                if numericIndices.contains(columnIndex), PluginNumericLiteral.isValid(value) {
                    return value
                }
                return "'\(escapeStringLiteral(value))'"
            }
        }
        return "  (\(values.joined(separator: ", ")))"
    }
}
