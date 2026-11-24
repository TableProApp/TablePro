//
//  XLSXImportSheet.swift
//  XLSXImportPlugin
//

import Foundation
import TableProPluginKit
import TableProTabularIO

nonisolated struct XLSXImportSheet {
    enum ReadError: LocalizedError {
        case noWorksheet

        var errorDescription: String? {
            switch self {
            case .noWorksheet:
                return String(localized: "The workbook has no worksheet to read.")
            }
        }
    }

    // Excel stores at most 32,767 characters in a cell and Google Sheets 50,000; 1 MiB of UTF-8 holds either.
    static let cellByteLimit = 1 << 20

    // One read is the header, a batch or the detection sample. Capped at what the reader buffers for one workbook part.
    static let readByteLimit = ZipArchive.bufferedEntryLimit

    let header: [String]?
    private let source: XLSXSheetSource
    private let columns: [Int]
    private let dataRows: [Int]

    init(source: XLSXSheetSource, hasHeaderRow: Bool) throws {
        let columns = Array(0..<source.columnCount)
        let occupied = source.occupiedRows()
        self.source = source
        self.columns = columns
        guard hasHeaderRow else {
            header = columns.map(Self.placeholderName)
            dataRows = occupied
            return
        }
        guard let headerRow = occupied.first else {
            header = nil
            dataRows = []
            return
        }
        let headerCells = try Self.rows([headerRow], of: source, columns: columns).first?.values ?? []
        header = Self.headerNames(from: headerCells)
        dataRows = Array(occupied.dropFirst())
    }

    static func read(at url: URL, hasHeaderRow: Bool, isCancelled: () -> Bool) throws -> XLSXImportSheet {
        let workbook = try XLSXWorkbook(contentsOf: url, isCancelled: isCancelled)
        guard let sheet = workbook.sheets.first(where: { !$0.isHidden }) ?? workbook.sheets.first else {
            throw ReadError.noWorksheet
        }
        let source = try workbook.source(for: sheet, isCancelled: isCancelled)
        return try XLSXImportSheet(source: source, hasHeaderRow: hasHeaderRow)
    }

    static func headerNames(from row: [String?]) -> [String] {
        ImportFieldNaming.uniqueNames(for: row, placeholder: placeholderName)
    }

    static func placeholderName(_ index: Int) -> String {
        "column\(index + 1)"
    }

    var rowCount: Int { dataRows.count }

    func rows(_ range: Range<Int>) throws -> [(line: Int, values: [String?])] {
        try Self.rows(dataRows[range.clamped(to: dataRows.indices)], of: source, columns: columns)
    }

    private static func rows(
        _ picked: some Collection<Int>,
        of source: XLSXSheetSource,
        columns: [Int]
    ) throws -> [(line: Int, values: [String?])] {
        try checkTextSize(of: picked, in: source, columns: columns)
        var result: [(line: Int, values: [String?])] = []
        result.reserveCapacity(picked.count)
        source.scan(columns: columns, rows: picked, absentKind: .missing) { row, cells in
            result.append((source.sheetReference(row: row, column: 0).row + 1, values(of: cells)))
            return true
        }
        return result
    }

    // Measured before any cell becomes a String: one shared string can back every cell, so a small file can expand to gigabytes.
    private static func checkTextSize(
        of picked: some Collection<Int>,
        in source: XLSXSheetSource,
        columns: [Int]
    ) throws {
        var total = 0
        var failure: PluginImportError?
        source.scan(columns: columns, rows: picked, absentKind: .missing) { row, cells in
            for index in 0..<cells.count {
                let length = cells.bytes[index].count
                guard length <= cellByteLimit else {
                    failure = .importFailed(String(
                        format: String(localized: "Cell %1$@ holds more than %2$@ of text, so the workbook was not read."),
                        source.sheetReference(row: row, column: columns[index]).text,
                        byteCount(cellByteLimit)))
                    return false
                }
                total += length
            }
            guard total <= readByteLimit else {
                failure = .importFailed(String(
                    format: String(localized: "Rows read together hold more than %1$@ of text by row %2$@, so the workbook was not read."),
                    byteCount(readByteLimit),
                    (source.sheetReference(row: row, column: 0).row + 1).formatted()))
                return false
            }
            return true
        }
        if let failure { throw failure }
    }

    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private static func values(of cells: TabularRowCells) -> [String?] {
        (0..<cells.count).map { index in
            switch cells.kinds[index] {
            case .missing:
                return nil
            case .boolean:
                // The cell stores 1 or 0, which every engine casts to a boolean; TRUE and FALSE are only how Excel shows it.
                return cells.string(at: index) == "TRUE" ? "1" : "0"
            default:
                return cells.string(at: index)
            }
        }
    }
}
