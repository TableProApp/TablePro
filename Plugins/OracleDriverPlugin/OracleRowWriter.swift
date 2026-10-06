//
//  OracleRowWriter.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

/// The INSERT, UPDATE and DELETE statements a grid save sends to Oracle, with `?` placeholders.
///
/// A keyed row is found by its primary key alone. A keyless row is found by every column it has, bounded with
/// `ROWNUM = 1` so a save never touches a second row that looks the same, and a change whose match would need a
/// column that cannot be compared is refused rather than sent without it.
///
/// Every value is written for the type the host reports for its column, so nothing depends on the session's NLS
/// settings. Measured on 23ai: a DATE or TIMESTAMP value is converted with an explicit mask, because the same text
/// assigned or compared bare fails with ORA-01861 under the default `DD-MON-RR`; a number is written as a literal,
/// because a bound `123.45` fails with ORA-01722 once `NLS_NUMERIC_CHARACTERS` is `,.`; and NULL is the literal,
/// because a NULL bind into an object-type column fails with ORA-00932.
internal struct OracleRowWriter {
    /// What the grid stages for a column the user leaves to the server's default. It is a marker, never a value.
    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    /// A keyed delete carries at most this many key values. One statement with 32,767 binds took 30 seconds on 23ai
    /// and one with 1,000 took 0.07, and a statement that outlives the query timeout closes the session.
    static let maxValuesPerDelete = 1_000

    static let dateMask = "YYYY-MM-DD HH24:MI:SS"
    static let timestampMask = "YYYY-MM-DD HH24:MI:SS.FF"
    static let timestampWithTimeZoneMask = "YYYY-MM-DD HH24:MI:SS.FFTZH:TZM"

    let qualifiedTable: String
    let columns: [String]
    let primaryKeyColumns: [String]
    var context = PluginRowWriteContext()

    func rowWrites(
        for changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        var deletes: [PluginRowChange] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex],
                      let write = insert(values: values, rowIndex: change.rowIndex) else { continue }
                writes.append(write)
            case .update:
                guard let write = try update(change) else { continue }
                writes.append(write)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                deletes.append(change)
            }
        }
        return writes + (try deleteWrites(for: deletes))
    }

    // MARK: - Statements

    /// Oracle has no `DEFAULT VALUES`. A row whose every column is the server's is written as one column's `DEFAULT`,
    /// which an identity or virtual column takes (measured on 23ai).
    private func insert(values: [PluginCellValue], rowIndex: Int) -> PluginRowWrite? {
        guard let firstColumn = columns.first else { return nil }
        var names: [String] = []
        var placeholders: [String] = []
        var parameters: [PluginCellValue] = []
        for (column, value) in zip(columns, values) where !context.serverOwnedColumns.contains(column) {
            names.append(Self.quote(column))
            placeholders.append(value == Self.defaultMarker ? "DEFAULT" : sql(for: value, column: column, into: &parameters))
        }
        guard !names.isEmpty else {
            return PluginRowWrite(
                statement: "INSERT INTO \(qualifiedTable) (\(Self.quote(firstColumn))) VALUES (DEFAULT)",
                rowIndices: [rowIndex]
            )
        }
        let statement = "INSERT INTO \(qualifiedTable) (\(names.joined(separator: ", "))) "
            + "VALUES (\(placeholders.joined(separator: ", ")))"
        return PluginRowWrite(statement: statement, parameters: parameters, rowIndices: [rowIndex])
    }

    private func update(_ change: PluginRowChange) throws -> PluginRowWrite? {
        guard !change.cellChanges.isEmpty else { return nil }
        if let owned = change.cellChanges.first(where: { context.serverOwnedColumns.contains($0.columnName) }) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.serverOwnedReason(owned.columnName))
        }
        var parameters: [PluginCellValue] = []
        let assignments = change.cellChanges.map { cell -> String in
            let column = Self.quote(cell.columnName)
            guard cell.newValue != Self.defaultMarker else { return "\(column) = DEFAULT" }
            return "\(column) = \(sql(for: cell.newValue, column: cell.columnName, into: &parameters))"
        }
        let match = try rowMatch(for: change, parameters: &parameters)
        let bound = primaryKeyColumns.isEmpty ? " AND ROWNUM = 1" : ""
        let statement = "UPDATE \(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(match)\(bound)"
        return PluginRowWrite(statement: statement, parameters: parameters, rowIndices: [change.rowIndex])
    }

    private func deleteWrites(for changes: [PluginRowChange]) throws -> [PluginRowWrite] {
        guard !primaryKeyColumns.isEmpty else {
            return try changes.map { change in
                var parameters: [PluginCellValue] = []
                let match = try rowMatch(for: change, parameters: &parameters)
                return PluginRowWrite(
                    statement: "DELETE FROM \(qualifiedTable) WHERE \(match) AND ROWNUM = 1",
                    parameters: parameters,
                    rowIndices: [change.rowIndex]
                )
            }
        }
        let rowsPerStatement = max(Self.maxValuesPerDelete / primaryKeyColumns.count, 1)
        return try stride(from: 0, to: changes.count, by: rowsPerStatement).map { start in
            let chunk = changes[start..<min(start + rowsPerStatement, changes.count)]
            var parameters: [PluginCellValue] = []
            let matches = try chunk.map { change -> String in
                let match = try rowMatch(for: change, parameters: &parameters)
                return primaryKeyColumns.count > 1 ? "(\(match))" : match
            }
            return PluginRowWrite(
                statement: "DELETE FROM \(qualifiedTable) WHERE \(matches.joined(separator: " OR "))",
                parameters: parameters,
                rowIndices: chunk.map(\.rowIndex)
            )
        }
    }

    // MARK: - Row Match

    private func rowMatch(for change: PluginRowChange, parameters: inout [PluginCellValue]) throws -> String {
        primaryKeyColumns.isEmpty
            ? try keylessMatch(for: change, parameters: &parameters)
            : try keyedMatch(for: change, parameters: &parameters)
    }

    private func keyedMatch(for change: PluginRowChange, parameters: inout [PluginCellValue]) throws -> String {
        try primaryKeyColumns.map { column in
            guard let value = originalValue(of: column, in: change), !value.isNull else {
                throw PluginRowWriteRefusal(
                    rowIndex: change.rowIndex,
                    reason: String(localized: "The row's primary key is not loaded, so the row cannot be found.")
                )
            }
            return "\(Self.quote(column)) = \(sql(for: value, column: column, into: &parameters))"
        }.joined(separator: " AND ")
    }

    private func keylessMatch(for change: PluginRowChange, parameters: inout [PluginCellValue]) throws -> String {
        guard let originalRow = change.originalRow else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "The table has no primary key, so this row cannot be identified.")
            )
        }
        let conditions = try zip(columns, originalRow).map { column, value -> String in
            guard !value.isNull else { return "\(Self.quote(column)) IS NULL" }
            guard isComparable(column) else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.unmatchableReason(column))
            }
            return "\(Self.quote(column)) = \(sql(for: value, column: column, into: &parameters))"
        }
        guard !conditions.isEmpty else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "The table has no primary key, so this row cannot be identified.")
            )
        }
        return conditions.joined(separator: " AND ")
    }

    private func originalValue(of column: String, in change: PluginRowChange) -> PluginCellValue? {
        if let index = columns.firstIndex(of: column), let row = change.originalRow, index < row.count {
            return row[index]
        }
        return change.cellChanges.first { $0.columnName == column }?.oldValue
    }

    /// Whether a keyless match can compare the column with `=`. Measured on 23ai, everything outside the scalar types
    /// fails or matches nothing: a LOB or VECTOR raises ORA-22848, a LONG ORA-00997, XMLTYPE and object types
    /// ORA-00932, and a JSON column compared with its own text matches no row at all. `IS NULL` works on every one of
    /// them. The host's exclusions and text-compared columns count too, because Oracle has no conversion that renders
    /// a value the way the grid read it.
    private func isComparable(_ column: String) -> Bool {
        guard !context.rowMatchExcludedColumns.contains(column),
              !context.rowMatchTextColumns.contains(column) else { return false }
        guard let typeName = context.columnTypeNames[column] else { return true }
        return Self.comparableTypes.contains(OracleTypeCatalog.baseTypeName(typeName))
    }

    private static let comparableTypes: Set<String> = [
        "VARCHAR2", "VARCHAR", "NVARCHAR2", "CHAR", "NCHAR",
        "NUMBER", "FLOAT", "INTEGER", "INT", "SMALLINT", "DECIMAL", "DEC", "NUMERIC", "REAL", "DOUBLE PRECISION",
        "BINARY_FLOAT", "BINARY_DOUBLE", "BINARY_INTEGER", "PLS_INTEGER",
        "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE",
        "INTERVAL DAY TO SECOND", "INTERVAL YEAR TO MONTH",
        "RAW", "ROWID", "UROWID", "BOOLEAN"
    ]

    // MARK: - Values

    /// Text for a column of a known type that is not a number is quoted here: left as `?`, it would reach the
    /// placeholder writer, which writes numeric-looking text unquoted, so `00123` would be stored in a VARCHAR2 as
    /// `123` and a keyless match on it would compare the column as a number. Text over the literal limit stays `?` and
    /// is bound. A column of no known type keeps the plain `?`.
    private func sql(for value: PluginCellValue, column: String, into parameters: inout [PluginCellValue]) -> String {
        guard let typeName = context.columnTypeNames[column] else {
            guard !value.isNull else { return "NULL" }
            parameters.append(value)
            return "?"
        }
        let kind = OracleValueKind(typeName: typeName)
        switch value {
        case .null:
            return "NULL"
        case .bytes:
            parameters.append(value)
            return "?"
        case .text(let text):
            if let literal = kind.inlineSQL(for: text) { return literal }
            if !kind.isNumeric, let quoted = OracleBindPlaceholders.quotedLiteral(text) {
                return kind.converting(quoted)
            }
            parameters.append(value)
            return kind.converting("?")
        }
    }

    // MARK: - Helpers

    static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func serverOwnedReason(_ column: String) -> String {
        String(format: String(localized: "The server fills in %@, so it cannot be given a value."), column)
    }

    private static func unmatchableReason(_ column: String) -> String {
        String(
            format: String(localized: "This table has no primary key, and %@ cannot be compared to find the row."),
            column
        )
    }
}

/// How a value is written for the type of the column it goes into.
internal enum OracleValueKind: Equatable {
    case date
    case timestamp
    case timestampWithTimeZone
    case timestampWithLocalTimeZone
    case number
    case binaryFloat
    case binaryDouble
    case other

    init(typeName: String) {
        switch OracleTypeCatalog.baseTypeName(typeName) {
        case "DATE": self = .date
        case "TIMESTAMP": self = .timestamp
        case "TIMESTAMP WITH TIME ZONE": self = .timestampWithTimeZone
        case "TIMESTAMP WITH LOCAL TIME ZONE": self = .timestampWithLocalTimeZone
        case "NUMBER", "FLOAT", "INTEGER", "INT", "SMALLINT", "DECIMAL", "DEC", "NUMERIC", "REAL",
             "DOUBLE PRECISION", "BINARY_INTEGER", "PLS_INTEGER":
            self = .number
        case "BINARY_FLOAT": self = .binaryFloat
        case "BINARY_DOUBLE": self = .binaryDouble
        default: self = .other
        }
    }

    var isNumeric: Bool {
        switch self {
        case .number, .binaryFloat, .binaryDouble: return true
        case .date, .timestamp, .timestampWithTimeZone, .timestampWithLocalTimeZone, .other: return false
        }
    }

    /// A text operand, a literal or `?`, as the column's type takes it.
    ///
    /// A TIMESTAMP WITH LOCAL TIME ZONE value reads as the session's wall clock with that instant's offset, which
    /// `TO_TIMESTAMP` rejects (ORA-01830). `TO_TIMESTAMP_TZ` takes it, and text without an offset in the session's
    /// zone, so the value round-trips through SET and a keyless match whatever the session and database zones are
    /// (measured on 23ai with the session at `+07:00` and at `America/New_York` against a `+00:00` database).
    func converting(_ operand: String) -> String {
        switch self {
        case .date:
            return "TO_DATE(\(operand), '\(OracleRowWriter.dateMask)')"
        case .timestamp:
            return "TO_TIMESTAMP(\(operand), '\(OracleRowWriter.timestampMask)')"
        case .timestampWithTimeZone, .timestampWithLocalTimeZone:
            return "TO_TIMESTAMP_TZ(\(operand), '\(OracleRowWriter.timestampWithTimeZoneMask)')"
        case .number, .binaryFloat, .binaryDouble, .other:
            return operand
        }
    }

    /// The value written into the statement itself, or nil to bind it.
    ///
    /// A BINARY_FLOAT or BINARY_DOUBLE literal carries its `f` or `d` suffix, because a bare literal is read as a
    /// NUMBER first and `1.7976931348623157e+308` overflows it (ORA-01426). Text that is not a number, such as `inf`
    /// or `nan`, is bound and the server converts it.
    func inlineSQL(for text: String) -> String? {
        switch self {
        case .number:
            return OracleNumericLiteral.isValid(text) ? text : nil
        case .binaryFloat:
            return OracleNumericLiteral.isValid(text) ? text + "f" : nil
        case .binaryDouble:
            return OracleNumericLiteral.isValid(text) ? text + "d" : nil
        case .date, .timestamp, .timestampWithTimeZone, .timestampWithLocalTimeZone:
            let keyword = text.trimmingCharacters(in: .whitespaces).uppercased()
            return Self.temporalFunctions.contains(keyword) ? keyword : nil
        case .other:
            return nil
        }
    }

    private static let temporalFunctions: Set<String> = [
        "SYSDATE", "SYSTIMESTAMP", "CURRENT_DATE", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP"
    ]
}

/// An Oracle numeric literal in ASCII: an optional sign, digits with at most one decimal point, and an optional
/// exponent. It is written into the statement unquoted, so nothing else may pass.
internal enum OracleNumericLiteral {
    static func isValid(_ text: String) -> Bool {
        var bytes = Array(text.utf8)[...]
        if let first = bytes.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            bytes = bytes.dropFirst()
        }
        let integerDigits = bytes.prefix(while: isDigit).count
        bytes = bytes.dropFirst(integerDigits)
        var fractionDigits = 0
        if bytes.first == UInt8(ascii: ".") {
            bytes = bytes.dropFirst()
            fractionDigits = bytes.prefix(while: isDigit).count
            bytes = bytes.dropFirst(fractionDigits)
        }
        guard integerDigits + fractionDigits > 0 else { return false }
        if let marker = bytes.first, marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                bytes = bytes.dropFirst()
            }
            let exponentDigits = bytes.prefix(while: isDigit).count
            guard exponentDigits > 0 else { return false }
            bytes = bytes.dropFirst(exponentDigits)
        }
        return bytes.isEmpty
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
