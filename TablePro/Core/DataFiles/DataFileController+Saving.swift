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
    case unencodable(row: Int, column: Int, character: Character, encoding: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return String(localized: "The file has not finished opening.")
        case .unsupportedFormat:
            return String(localized: "This file cannot be saved in that format.")
        case .unencodable(let row, let column, let character, let encoding):
            return String(
                format: String(localized: "Row %@, column %@ contains “%@”, which %@ cannot store. Choose Save As and pick UTF-8."),
                row.formatted(),
                column.formatted(),
                String(character),
                encoding
            )
        case .failed(let message):
            return message
        }
    }
}

extension DataFileController {
    func write(to url: URL, typeName: String) throws {
        guard let table, loadState == .loaded else { throw DataFileSaveError.notLoaded }
        guard let format = DataFileKind.format(forSaveType: typeName) else {
            throw DataFileSaveError.unsupportedFormat
        }
        switch format {
        case .delimited:
            try writeDelimited(table, to: url, typeName: typeName)
        case .json, .jsonLines, .workbook:
            throw DataFileSaveError.unsupportedFormat
        }
    }

    func outputDialect(forType typeName: String, table: TabularTable) -> DelimitedDialect {
        var output = dialect ?? DelimitedDialect()
        if let delimiter = DataFileKind.delimiter(forSaveType: typeName) {
            output.delimiter = delimiter
        }
        output.hasHeaderRow = table.headerRowKey != nil
        return output
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
        } catch TabularWriteError.unencodable(let row, let column, let character, let encoding) {
            throw DataFileSaveError.unencodable(
                row: row + 1,
                column: column + 1,
                character: character,
                encoding: DataFileEncodingNames.name(for: encoding)
            )
        } catch TabularWriteError.couldNotCreate(let path) {
            throw DataFileSaveError.failed(String(format: String(localized: "Could not create %@."), path))
        } catch TabularWriteError.writeFailed(let message) {
            throw DataFileSaveError.failed(message)
        }
    }
}
