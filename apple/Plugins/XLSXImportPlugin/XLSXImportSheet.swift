//
//  XLSXImportSheet.swift
//  XLSXImportPlugin
//

import Foundation
import TableProPluginKit
import TableProTabularIO

struct XLSXImportSheet {
    enum ReadError: LocalizedError {
        case noWorksheet

        var errorDescription: String? {
            switch self {
            case .noWorksheet:
                return String(localized: "The workbook has no worksheet to read.")
            }
        }
    }

    let header: [String]?
    private let source: XLSXSheetSource
    private let columns: [Int]
    private let dataRows: [Int]

    init(source: XLSXSheetSource, hasHeaderRow: Bool) {
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
        let headerCells = Self.rows([headerRow], of: source, columns: columns).first?.values ?? []
        header = Self.headerNames(from: headerCells)
        dataRows = Array(occupied.dropFirst())
    }

    static func read(at url: URL, hasHeaderRow: Bool, isCancelled: () -> Bool) throws -> XLSXImportSheet {
        let workbook = try XLSXWorkbook(contentsOf: url, isCancelled: isCancelled)
        guard let sheet = workbook.sheets.first(where: { !$0.isHidden }) ?? workbook.sheets.first else {
            throw ReadError.noWorksheet
        }
        let source = try workbook.source(for: sheet, isCancelled: isCancelled)
        return XLSXImportSheet(source: source, hasHeaderRow: hasHeaderRow)
    }

    static func headerNames(from row: [String?]) -> [String] {
        ImportFieldNaming.uniqueNames(for: row, placeholder: placeholderName)
    }

    static func placeholderName(_ index: Int) -> String {
        "column\(index + 1)"
    }

    var rowCount: Int { dataRows.count }

    func rows(_ range: Range<Int>) -> [(line: Int, values: [String?])] {
        Self.rows(dataRows[range.clamped(to: dataRows.indices)], of: source, columns: columns)
    }

    private static func rows(
        _ picked: some Collection<Int>,
        of source: XLSXSheetSource,
        columns: [Int]
    ) -> [(line: Int, values: [String?])] {
        var result: [(line: Int, values: [String?])] = []
        result.reserveCapacity(picked.count)
        source.scan(columns: columns, rows: picked, absentKind: .missing) { row, cells in
            result.append((source.sheetReference(row: row, column: 0).row + 1, values(of: cells)))
            return true
        }
        return result
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
