//
//  DataFileController+Saving.swift
//  TablePro
//

import Foundation
import TableProTabular
import TableProTabularIO

enum DataFileSaveError: LocalizedError {
    case notLoaded
    case unsupportedFormat
    case unencodable(row: Int, column: String, character: String, encoding: String)
    case unencodableInHiddenRow(column: String, character: String, encoding: String)
    case unencodableColumnName(column: String, character: String, encoding: String)
    case invalidJSONValue(row: Int, column: String)
    case duplicateJSONKey(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return String(localized: "The file has not finished opening.")
        case .unsupportedFormat:
            return String(localized: "This file cannot be saved in that format.")
        case .unencodable(let row, let column, let character, let encoding):
            return String(
                format: String(localized: "Row %@, column “%@” contains %@, which %@ cannot store. Choose Save As and pick UTF-8."),
                row.formatted(),
                column,
                character,
                encoding
            )
        case .unencodableInHiddenRow(let column, let character, let encoding):
            return String(
                format: String(localized: "A row the filter hides holds %@ in column “%@”, which %@ cannot store. Clear the filter to find it, or choose Save As and pick UTF-8."),
                character,
                column,
                encoding
            )
        case .unencodableColumnName(let column, let character, let encoding):
            return String(
                format: String(localized: "The column name “%@” contains %@, which %@ cannot store. Rename the column, or choose Save As and pick UTF-8."),
                column,
                character,
                encoding
            )
        case .invalidJSONValue(let row, let column):
            return String(
                format: String(localized: "Row %@, column %@ is not valid JSON. Fix the value or clear it, then save again."),
                row.formatted(),
                column
            )
        case .duplicateJSONKey(let key):
            return String(format: String(localized: "Two columns are both named “%@”. Rename one, then save again."), key)
        case .failed(let message):
            return message
        }
    }
}

extension DataFileController {
    func write(to url: URL, typeName: String) throws {
        lastWrittenDialect = nil
        guard let table, loadState == .loaded else { throw DataFileSaveError.notLoaded }
        guard let format = DataFileKind.format(forSaveType: typeName) else {
            throw DataFileSaveError.unsupportedFormat
        }
        switch format {
        case .delimited:
            try writeDelimited(table, to: url, typeName: typeName)
        case .json:
            let keepsLines = kind?.format == .json && content?.jsonSource?.shape == .lines
            try writeJSON(table, to: url, shape: keepsLines ? .lines : .array)
        case .jsonLines:
            try writeJSON(table, to: url, shape: .lines)
        case .workbook:
            throw DataFileSaveError.unsupportedFormat
        }
    }

    private func writeJSON(_ table: TabularTable, to url: URL, shape: JSONTableShape) throws {
        let source = content?.jsonSource
        let keepsSource = source?.shape == shape
        let typesText = source == nil
        let kinds = Dictionary(uniqueKeysWithValues: table.columnIDs.map { ($0, kind(of: $0)) })
        let rows = table.jsonOutputRows(sourceKeys: keepsSource ? source?.keys : nil) { cell, id in
            try Self.jsonLiteral(for: cell, columnKind: kinds[id] ?? .text, typesText: typesText)
        }
        let writer: JSONTableWriter
        if keepsSource, let source {
            writer = JSONTableWriter(source: source, keyChanges: table.jsonKeyChanges(sourceKeys: source.keys))
        } else {
            writer = JSONTableWriter(shape: shape)
        }
        do {
            try writer.write(to: url, rows: rows)
        } catch JSONTableWriteError.duplicateKey(let key) {
            throw DataFileSaveError.duplicateJSONKey(key)
        } catch JSONTableWriteError.invalidLiteral, JSONTableWriteError.literalSpansLines {
            throw DataFileSaveError.failed(String(localized: "A value could not be written as JSON."))
        } catch JSONTableWriteError.sourceRowUnavailable {
            throw DataFileSaveError.failed(String(localized: "The original file changed while it was open. Reload it, then save again."))
        } catch TabularWriteError.couldNotCreate(let path) {
            throw DataFileSaveError.failed(String(format: String(localized: "Could not create %@."), path))
        } catch TabularWriteError.writeFailed(let message) {
            throw DataFileSaveError.failed(message)
        }
        if let failure = rows.status.failure {
            throw DataFileSaveError.invalidJSONValue(
                row: (table.rowOrder.logicalRow(ofKey: failure.key) ?? 0) + 1,
                column: table.column(failure.column)?.name ?? ""
            )
        }
    }

    nonisolated static func jsonLiteral(
        for cell: TabularCell,
        columnKind: TabularInferredKind,
        typesText: Bool
    ) throws -> String {
        guard typesText, cell.kind == .text else {
            return try JSONValueTyping.literal(for: cell.text, originalKind: cell.kind)
        }
        let kind = jsonKind(forNewValue: cell.text, columnKind: columnKind)
        return try JSONValueTyping.literal(for: cell.text, originalKind: kind == .null ? .text : kind)
    }

    func outputDialect(forType typeName: String, table: TabularTable) -> DelimitedDialect {
        var output = dialect ?? DelimitedDialect()
        if let delimiter = DataFileKind.delimiter(forSaveType: typeName) {
            output.delimiter = delimiter
        }
        if let saveEncoding, saveEncoding != output.encoding {
            output.encoding = saveEncoding
            output.hasByteOrderMark = !saveEncoding.byteOrderMark.isEmpty && saveEncoding != .utf8
        }
        output.hasHeaderRow = table.headerRowKey != nil
        return output
    }

    var offersSaveEncoding: Bool {
        switch kind?.format {
        case .delimited?, .workbook?:
            return true
        case .json?, .jsonLines?, nil:
            return false
        }
    }

    private func writeDelimited(_ table: TabularTable, to url: URL, typeName: String) throws {
        let source = content?.delimitedSource
        let usesSource = source != nil && kind?.format == .delimited
        let headerNames: [String]? = usesSource && table.headerRowKey == 0
            ? source?.decodedFields(row: 0)
            : nil
        let writer = DelimitedWriter(dialect: outputDialect(forType: typeName, table: table), source: usesSource ? source : nil)
        do {
            try writer.write(
                to: url,
                rows: table.outputRows(sourceHeaderNames: headerNames, copiesSourceRows: usesSource),
                endsWithLineTerminator: source?.index.endsWithLineTerminator ?? true
            )
            lastWrittenDialect = writer.dialect
        } catch TabularWriteError.unencodable(let row, let column, let character, let encoding) {
            throw unencodableError(outputRow: row, column: column, character: character, encoding: encoding, in: table)
        } catch TabularWriteError.couldNotCreate(let path) {
            throw DataFileSaveError.failed(String(format: String(localized: "Could not create %@."), path))
        } catch TabularWriteError.writeFailed(let message) {
            throw DataFileSaveError.failed(message)
        }
    }

    private func unencodableError(
        outputRow: Int,
        column: Int,
        character: Character,
        encoding: TabularTextEncoding,
        in table: TabularTable
    ) -> DataFileSaveError {
        let columnName = table.columns.indices.contains(column) ? table.columns[column].name : (column + 1).formatted()
        let described = Self.describe(character)
        let writesHeader = table.headerRowKey != nil
        if writesHeader, outputRow == 0 {
            return .unencodableColumnName(column: columnName, character: described, encoding: encoding.displayName)
        }
        let logicalRow = outputRow - (writesHeader ? 1 : 0)
        guard logicalRow >= 0, logicalRow < table.rowCount else {
            return .unencodableInHiddenRow(column: columnName, character: described, encoding: encoding.displayName)
        }
        let key = table.key(atRow: logicalRow)
        guard let position = displayPosition(ofKey: key) else {
            return .unencodableInHiddenRow(column: columnName, character: described, encoding: encoding.displayName)
        }
        reveal(key: key)
        return .unencodable(row: position + 1, column: columnName, character: described, encoding: encoding.displayName)
    }

    nonisolated static func describe(_ character: Character) -> String {
        let isInvisible = character.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace || [.control, .format].contains(scalar.properties.generalCategory)
        }
        guard isInvisible else { return "“\(character)”" }
        return character.unicodeScalars
            .map { String(format: "U+%04X %@", $0.value, $0.properties.name ?? "") }
            .joined(separator: ", ")
    }
}
