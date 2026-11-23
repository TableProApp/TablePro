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
nonisolated internal struct SQLExportRowValueEncoder {
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

    // What a text cell of each included column may be written as bare, parallel to `includedColumnIndices`.
    private enum BareText {
        case never
        case number
        case unsignedInteger
    }

    private let bareText: [BareText]
    private let databaseTypeId: String
    private let stringLiteralPrefix: String
    private let escapeStringLiteral: (String) -> String

    internal init(
        columns: [String],
        columnTypeNames: [String],
        excludedColumnNames: Set<[UInt8]>,
        databaseTypeId: String,
        escapeStringLiteral: @escaping (String) -> String
    ) {
        includedColumnIndices = columns.enumerated().compactMap { index, name in
            excludedColumnNames.contains(PluginExportSpelling.key(name)) ? nil : index
        }
        let readsBitAsNumber = SqlDialect.from(databaseTypeId: databaseTypeId) == .mysql
        bareText = includedColumnIndices.map { index in
            guard index < columnTypeNames.count else { return .never }
            if PluginExportUtilities.isNumericColumnType(columnTypeNames[index]) { return .number }
            if readsBitAsNumber, Self.isBitType(columnTypeNames[index]) { return .unsignedInteger }
            return .never
        }
        self.databaseTypeId = databaseTypeId
        // SQL Server reads '...' in the database's code page, so 日本 in an nvarchar restored as ??, and db-lib
        // reports an nvarchar column as varchar, so the type cannot pick the columns. N'...' converts back into any
        // text column. Measured on SQL Server 2022.
        stringLiteralPrefix = databaseTypeId == "SQL Server" ? "N'" : "'"
        self.escapeStringLiteral = escapeStringLiteral
    }

    // MySQL stores a quoted literal's bytes in a BIT column, so '5' restores as 53. The driver reads the value as a
    // decimal number, which the server takes back bare. StarRocks' BITMAP is not this type.
    private static func isBitType(_ typeName: String) -> Bool {
        let upper = typeName.uppercased()
        return upper == "BIT" || upper.hasPrefix("BIT(")
    }

    private static func isUnsignedInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    internal var writesNothing: Bool { includedColumnIndices.isEmpty }

    internal func columnNames(from columns: [String]) -> [String] {
        includedColumnIndices.map { columns[$0] }
    }

    // One string grown in place: an export renders every row, and a string per value plus a join cost more than
    // the values.
    internal func render(_ row: [PluginCellValue]) -> String {
        var line = "  ("
        line.reserveCapacity(Self.estimatedLength(of: row, columns: includedColumnIndices))
        for (position, columnIndex) in includedColumnIndices.enumerated() {
            if position > 0 { line += ", " }
            guard columnIndex < row.count else {
                line += "NULL"
                continue
            }
            switch row[columnIndex] {
            case .null:
                line += "NULL"
            case .bytes(let data):
                if SQLExportBinaryLiteral.exceedsLiteralCeiling(data, databaseTypeId: databaseTypeId) {
                    unrepresentableValues.record()
                }
                line += SQLExportBinaryLiteral.render(data, databaseTypeId: databaseTypeId)
            case .text(let value):
                switch bareText[position] {
                case .number where PluginNumericLiteral.isValid(value),
                     .unsignedInteger where Self.isUnsignedInteger(value):
                    line += value
                default:
                    line += stringLiteralPrefix
                    line += escapeStringLiteral(value)
                    line += "'"
                }
            }
        }
        line += ")"
        return line
    }

    private static func estimatedLength(of row: [PluginCellValue], columns: [Int]) -> Int {
        var length = 3 + 2 * columns.count
        for columnIndex in columns where columnIndex < row.count {
            switch row[columnIndex] {
            case .null: length += 4
            case .text(let value): length += value.utf8.count + 3
            case .bytes(let data): length += data.count * 2 + 3
            }
        }
        return length
    }
}
