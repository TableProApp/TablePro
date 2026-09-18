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

    /// The values this encoder rendered that the engine cannot carry in one statement whatever
    /// spelling is used. A class because rendering a row is not supposed to look like a mutation,
    /// and the count has to survive the `let` the stream loop holds the encoder in.
    internal final class UnrepresentableValueCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        internal func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        internal var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    internal let unrepresentableValues = UnrepresentableValueCount()

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
                if SQLExportBinaryLiteral.exceedsLiteralCeiling(data, databaseTypeId: databaseTypeId) {
                    unrepresentableValues.record()
                }
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
