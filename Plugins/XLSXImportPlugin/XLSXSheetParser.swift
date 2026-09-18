//
//  XLSXSheetParser.swift
//  XLSXImportPlugin
//

import Foundation
import TableProPluginKit

/// Reads rows out of a workbook's first worksheet.
///
/// Two things make a sheet more than a table of values. Text is usually not in the sheet at all: it
/// sits in `sharedStrings.xml` and the cell holds an index, so a sheet read without that file comes
/// back as numbers. And a row omits its empty cells rather than writing them, so position has to
/// come from each cell's own `r` reference (`C4`) instead of from counting.
enum XLSXSheetParser {
    enum ParseError: LocalizedError {
        case noWorksheet

        var errorDescription: String? {
            switch self {
            case .noWorksheet:
                return String(localized: "The workbook has no worksheet to read.")
            }
        }
    }

    /// A cell's column index, from the letters in its reference. `A` is 0, `Z` 25, `AA` 26.
    static func columnIndex(fromReference reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue else { return nil }
            if ascii >= 65, ascii <= 90 {
                index = index * 26 + Int(ascii - 64)
                sawLetter = true
            } else if ascii >= 48, ascii <= 57 {
                break
            } else {
                return nil
            }
        }
        return sawLetter ? index - 1 : nil
    }

    /// The worksheet part of the first sheet. Named parts vary, so the first `sheet*.xml` under
    /// `xl/worksheets/` is taken rather than assuming `sheet1.xml`.
    static func firstWorksheetPath(in paths: [String]) -> String? {
        paths
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
            .first
    }

    static func sharedStrings(from data: Data) -> [String] {
        let delegate = SharedStringsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    /// Every row of the sheet, each padded to the widest row so a caller can zip them with a header
    /// without checking lengths.
    static func rows(from data: Data, sharedStrings: [String]) -> [[String?]] {
        let delegate = SheetDelegate(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        let width = delegate.rows.map(\.count).max() ?? 0
        return delegate.rows.map { row in
            row.count == width ? row : row + Array(repeating: nil, count: width - row.count)
        }
    }
}

/// `sharedStrings.xml` holds one `<si>` per string, and a string can be split across several `<t>`
/// runs when parts of it are formatted differently. The runs are concatenated, or a styled word in
/// the middle of a cell would truncate the value.
private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current: String?
    private var isInsideText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "si": current = ""
        case "t": isInsideText = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideText, current != nil else { return }
        current? += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "t": isInsideText = false
        case "si":
            strings.append(current ?? "")
            current = nil
        default: break
        }
    }
}

private final class SheetDelegate: NSObject, XMLParserDelegate {
    private(set) var rows: [[String?]] = []

    private let sharedStrings: [String]
    private var currentRow: [String?] = []
    private var currentColumn = 0
    private var cellType = ""
    private var value: String?
    private var isInsideValue = false
    private var isInsideInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "row":
            currentRow = []
        case "c":
            cellType = attributes["t"] ?? ""
            value = nil
            currentColumn = attributes["r"]
                .flatMap { XLSXSheetParser.columnIndex(fromReference: $0) }
                ?? currentRow.count
        case "v":
            isInsideValue = true
            value = ""
        case "t":
            /// An inline string lives in the cell rather than in `sharedStrings.xml`. Numbers and
            /// LibreOffice both write them.
            isInsideInlineText = true
            value = value ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideValue || isInsideInlineText else { return }
        value = (value ?? "") + string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "v":
            isInsideValue = false
        case "t":
            isInsideInlineText = false
        case "c":
            place(resolvedValue(), at: currentColumn)
        case "row":
            rows.append(currentRow)
            currentRow = []
        default:
            break
        }
    }

    /// A cell whose type is `s` holds an index into the shared strings rather than the text itself.
    /// An index the table does not have is left as the raw value rather than dropped, so a damaged
    /// workbook still imports something the user can see is wrong.
    private func resolvedValue() -> String? {
        guard let value else { return nil }
        guard cellType == "s" else { return value }
        guard let index = Int(value), index >= 0, index < sharedStrings.count else { return value }
        return sharedStrings[index]
    }

    /// A row omits the cells it has no value for, so a cell lands at the index its own reference
    /// names and the gap before it is filled with nulls.
    private func place(_ value: String?, at column: Int) {
        guard column >= 0 else { return }
        while currentRow.count < column {
            currentRow.append(nil)
        }
        if currentRow.count == column {
            currentRow.append(value)
        } else {
            currentRow[column] = value
        }
    }
}
