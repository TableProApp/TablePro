//
//  XLSXWriter.swift
//  TablePro
//
//  Lightweight XLSX writer that creates Excel files without external dependencies.
//  XLSX format = ZIP archive containing XML files (Office Open XML).
//
//  Performance: Uses inline strings (no shared string table), Data buffers
//  (not String concatenation), and batch row processing to handle 100K+ row
//  exports with bounded memory usage.
//

import Foundation
import os
import TableProPluginKit
import zlib

/// Writes data to XLSX format using raw ZIP file construction.
///
/// Uses inline strings (`t="inlineStr"`) instead of a shared string table
/// to avoid unbounded memory growth from caching every unique string value.
/// Rows are processed in batches and appended directly to per-sheet XML Data,
/// so raw row arrays can be released after each batch.
final class XLSXWriter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "XLSXWriter")

    /// Per-sheet metadata and accumulated XML data
    private var sheets: [(name: String, data: Data)] = []

    private static let maximumSheetNameLength = 31
    private var takenSheetNames: Set<String> = []

    /// Pre-cached column letter lookups
    private var columnLetterCache: [String] = []

    /// Tracks the current row number for the active sheet being built
    private var currentRowNumber: Int = 0

    /// Whether the current sheet has a header row (used for bold styling)
    private var currentSheetHasHeader: Bool = false

    enum CellValue: Equatable {
        case string(String)
        case number(String)
        case empty
    }

    enum ColumnNumbers: Equatable {
        case text
        case exact
        case approximate
        case untyped

        init(typeName: String, bitsAreStrings: Bool = false) {
            let base = Self.baseName(typeName)
            if base.isEmpty {
                self = .untyped
            } else if Self.bitTypes.contains(base) {
                self = bitsAreStrings ? .text : .exact
            } else if Self.approximateTypes.contains(base) {
                self = .approximate
            } else if Self.exactTypes.contains(base) {
                self = .exact
            } else if Self.textTypes.contains(base) || Self.textMarkers.contains(where: { base.contains($0) }) {
                self = .text
            } else {
                self = .untyped
            }
        }

        // `Nullable(UInt64)` and `LowCardinality(Nullable(Int32))` name the type inside. The base is the
        // first word without its width: `int4`, `Int64` and `INT UNSIGNED` are all `int`.
        private static func baseName(_ typeName: String) -> String {
            var name = typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while name.hasSuffix(")"), let open = name.firstIndex(of: "("),
                  ["nullable", "lowcardinality"].contains(String(name[..<open])) {
                name = String(name[name.index(after: open)...].dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }
            return String(name.prefix { $0.isLetter || $0 == "_" })
        }

        private static let exactTypes: Set<String> = [
            "int", "uint", "integer", "bigint", "smallint", "tinyint", "mediumint", "hugeint",
            "uinteger", "ubigint", "usmallint", "utinyint", "uhugeint", "decimal", "dec", "numeric",
            "number", "bignumeric", "serial", "bigserial", "smallserial", "money", "smallmoney", "year", "oid"
        ]

        private static let approximateTypes: Set<String> = [
            "float", "double", "real", "binary_float", "binary_double"
        ]

        private static let textTypes: Set<String> = ["enum", "set", "json", "jsonb", "name"]

        private static let bitTypes: Set<String> = ["bit", "varbit"]

        // PostgreSQL's `bit(n)` is a string of 0 and 1. SQL Server's is a flag and MySQL's reads as a number.
        static func bitsAreStrings(databaseTypeId: String) -> Bool {
            enginesWithBitStrings.contains(databaseTypeId)
        }

        private static let enginesWithBitStrings: Set<String> = [
            "PostgreSQL", "Redshift", "CockroachDB", "PGlite", "AlloyDB", "Citus", "Greenplum", "KingbaseES"
        ]

        private static let textMarkers = ["char", "text", "string", "clob"]
    }

    // Excel keeps 15 significant digits of a number.
    private static let maximumExactDigits = 15

    private var currentColumnNumbers: [ColumnNumbers] = []

    private let bitsAreStrings: Bool

    init(databaseTypeId: String = "") {
        bitsAreStrings = ColumnNumbers.bitsAreStrings(databaseTypeId: databaseTypeId)
    }

    // MARK: - Sheet Building API

    /// Begin a new worksheet. Must be followed by `addRows` calls and then `finishSheet`.
    func beginSheet(
        name: String,
        columns: [String],
        columnTypeNames: [String] = [],
        includeHeader: Bool,
        convertNullToEmpty: Bool
    ) {
        let sheetName = unusedSheetName(for: name)
        currentColumnNumbers = columnTypeNames.map { ColumnNumbers(typeName: $0, bitsAreStrings: bitsAreStrings) }
        currentRowNumber = 0
        currentSheetHasHeader = includeHeader

        let maxCols = max(columns.count, columnLetterCache.count)
        if maxCols > columnLetterCache.count {
            for i in columnLetterCache.count..<maxCols {
                columnLetterCache.append(columnLetter(i))
            }
        }

        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")

        if includeHeader {
            let headerCells: [CellValue] = columns.map { .string($0) }
            appendRow(headerCells, isHeader: true, to: &d)
        }

        sheets.append((name: sheetName, data: d))
    }

    /// Add a batch of raw rows to the current (last) sheet.
    /// Converts `[PluginCellValue]` to `CellValue` and writes XML immediately,
    /// so the caller can release the raw row data after this call returns.
    func addRows(_ rows: [[PluginCellValue]], convertNullToEmpty: Bool) {
        guard !sheets.isEmpty else { return }

        var sheetData = sheets[sheets.count - 1].data

        for row in rows {
            autoreleasepool {
                let cellRow: [CellValue] = row.enumerated().map { index, value -> CellValue in
                    switch value {
                    case .null:
                        return convertNullToEmpty ? .empty : .string("NULL")
                    case .bytes(let data):
                        if data.isEmpty { return .empty }
                        let hex = data.map { String(format: "%02X", $0) }.joined()
                        return .string("0x" + hex)
                    case .text(let val):
                        let numbers = index < currentColumnNumbers.count ? currentColumnNumbers[index] : .untyped
                        return Self.cell(forText: val, numbers: numbers)
                    }
                }
                appendRow(cellRow, isHeader: false, to: &sheetData)
            }
        }

        sheets[sheets.count - 1].data = sheetData
    }

    // A text column writes text whatever its values look like. A numeric column writes a number
    // unless Excel cannot hold it exactly. A column with no usable type name writes a number only
    // for a plain decimal of at most 15 digits, so ids, codes and padded values stay text.
    static func cell(forText text: String, numbers: ColumnNumbers) -> CellValue {
        guard !text.isEmpty else { return .empty }
        guard numbers != .text,
              !hasPaddingZero(text),
              let literal = JsonNumberNormalizer.numberLiteral(from: text),
              let value = Double(literal), value.isFinite else {
            return .string(text)
        }
        switch numbers {
        case .text:
            return .string(text)
        case .approximate:
            return .number(literal)
        case .exact:
            return significantDigitCount(of: literal) <= maximumExactDigits ? .number(literal) : .string(text)
        case .untyped:
            let isPlain = literal == text && !literal.contains("e")
            let digitCount = literal.filter { $0.isNumber }.count
            return isPlain && digitCount <= maximumExactDigits ? .number(literal) : .string(text)
        }
    }

    // ZEROFILL pads an integer for display, and a number cell would drop the padding.
    private static func hasPaddingZero(_ text: String) -> Bool {
        let digits = text.drop { $0 == "-" || $0 == "+" }
        guard digits.first == "0", let second = digits.dropFirst().first else { return false }
        return second.isNumber
    }

    private static func significantDigitCount(of literal: String) -> Int {
        let mantissa = literal.prefix { $0 != "e" && $0 != "E" }
        let digits = mantissa.filter(\.isNumber).drop { $0 == "0" }
        guard let last = digits.lastIndex(where: { $0 != "0" }) else { return 0 }
        return digits[...last].count
    }

    /// Finish the current sheet by closing the XML tags.
    func finishSheet() {
        guard !sheets.isEmpty else { return }
        sheets[sheets.count - 1].data.appendUTF8("</sheetData></worksheet>")
    }

    /// Finish the current sheet and start a continuation sheet with the same columns.
    /// The new sheet is named "BaseName (N)" where N increments.
    func continueSheet(
        baseName: String,
        columns: [String],
        columnTypeNames: [String] = [],
        includeHeader: Bool,
        convertNullToEmpty: Bool
    ) {
        finishSheet()
        beginSheet(
            name: baseName,
            columns: columns,
            columnTypeNames: columnTypeNames,
            includeHeader: includeHeader,
            convertNullToEmpty: convertNullToEmpty
        )
    }

    // MARK: - Legacy Convenience API

    /// Add a complete worksheet with all rows at once (legacy compatibility).
    /// For better memory usage, prefer `beginSheet` / `addRows` / `finishSheet`.
    func addSheet(
        name: String,
        columns: [String],
        columnTypeNames: [String] = [],
        rows: [[PluginCellValue]],
        includeHeader: Bool,
        convertNullToEmpty: Bool
    ) {
        beginSheet(
            name: name,
            columns: columns,
            columnTypeNames: columnTypeNames,
            includeHeader: includeHeader,
            convertNullToEmpty: convertNullToEmpty
        )
        addRows(rows, convertNullToEmpty: convertNullToEmpty)
        finishSheet()
    }

    /// Write the XLSX file to the given URL
    func write(to url: URL) async throws {
        let entries = archiveEntries()
        try await Task.detached(priority: .userInitiated) {
            let zipData = try ZipBuilder.build(entries: entries)
            try zipData.write(to: url, options: .atomic)
        }.value
    }

    private func archiveEntries() -> [ZipFileEntry] {
        var entries: [ZipFileEntry] = []

        entries.append(ZipFileEntry(path: "[Content_Types].xml", data: contentTypesXML()))
        entries.append(ZipFileEntry(path: "_rels/.rels", data: relsXML()))
        entries.append(ZipFileEntry(path: "xl/workbook.xml", data: workbookXML()))
        entries.append(ZipFileEntry(path: "xl/_rels/workbook.xml.rels", data: workbookRelsXML()))
        entries.append(ZipFileEntry(path: "xl/styles.xml", data: stylesXML()))

        for (index, sheet) in sheets.enumerated() {
            entries.append(ZipFileEntry(
                path: "xl/worksheets/sheet\(index + 1).xml",
                data: sheet.data
            ))
        }

        return entries
    }

    // MARK: - Row XML Generation

    /// Append a single row of cells to the given Data buffer using inline strings.
    /// Inline strings use `t="inlineStr"` with `<is><t>text</t></is>` to avoid
    /// the shared string table entirely (MEM-15 fix).
    private func appendRow(_ cells: [CellValue], isHeader: Bool, to data: inout Data) {
        currentRowNumber += 1
        let rowNum = currentRowNumber

        data.appendUTF8("<row r=\"\(rowNum)\">")

        for (colIndex, cell) in cells.enumerated() {
            let colLetter = colIndex < columnLetterCache.count
                ? columnLetterCache[colIndex]
                : columnLetter(colIndex)
            let cellRef = "\(colLetter)\(rowNum)"

            switch cell {
            case .string(let value):
                if isHeader {
                    // Header cells get bold style (s="1") + inline string
                    data.appendUTF8("<c r=\"\(cellRef)\" t=\"inlineStr\" s=\"1\"><is><t>")
                } else {
                    data.appendUTF8("<c r=\"\(cellRef)\" t=\"inlineStr\"><is><t>")
                }
                data.appendXMLEscaped(value)
                data.appendUTF8("</t></is></c>")
            case .number(let value):
                data.appendUTF8("<c r=\"\(cellRef)\"><v>")
                data.appendXMLEscaped(value)
                data.appendUTF8("</v></c>")
            case .empty:
                break
            }
        }

        data.appendUTF8("</row>")
    }

    // MARK: - XML Generation (Data-based to avoid O(n^2) String concatenation)

    private func contentTypesXML() -> Data {
        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">")
        d.appendUTF8("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>")
        d.appendUTF8("<Default Extension=\"xml\" ContentType=\"application/xml\"/>")
        d.appendUTF8("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>")
        d.appendUTF8("<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>")
        for index in sheets.indices {
            d.appendUTF8("<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>")
        }
        d.appendUTF8("</Types>")
        return d
    }

    private func relsXML() -> Data {
        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">")
        d.appendUTF8("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>")
        d.appendUTF8("</Relationships>")
        return d
    }

    private func workbookXML() -> Data {
        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">")
        d.appendUTF8("<sheets>")
        for (index, sheet) in sheets.enumerated() {
            d.appendUTF8("<sheet name=\"")
            d.appendXMLEscaped(sheet.name)
            d.appendUTF8("\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>")
        }
        d.appendUTF8("</sheets></workbook>")
        return d
    }

    private func workbookRelsXML() -> Data {
        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">")
        for index in sheets.indices {
            d.appendUTF8("<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>")
        }
        let nextId = sheets.count + 1
        d.appendUTF8("<Relationship Id=\"rId\(nextId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>")
        d.appendUTF8("</Relationships>")
        return d
    }

    private func stylesXML() -> Data {
        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">")
        d.appendUTF8("<fonts count=\"2\">")
        d.appendUTF8("<font><sz val=\"11\"/><name val=\"Calibri\"/></font>")
        d.appendUTF8("<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font>")
        d.appendUTF8("</fonts>")
        d.appendUTF8("<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>")
        d.appendUTF8("<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>")
        d.appendUTF8("<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>")
        d.appendUTF8("<cellXfs count=\"2\">")
        d.appendUTF8("<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>")
        d.appendUTF8("<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>")
        d.appendUTF8("</cellXfs>")
        d.appendUTF8("<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>")
        d.appendUTF8("</styleSheet>")
        return d
    }

    // MARK: - Helpers

    private func columnLetter(_ index: Int) -> String {
        var result = ""
        var n = index
        repeat {
            if let scalar = UnicodeScalar(65 + (n % 26)) {
                result = String(scalar) + result
            }
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    private func unusedSheetName(for requestedName: String) -> String {
        let base = sanitizeSheetName(requestedName)
        var candidate = base
        var number = 1
        while takenSheetNames.contains(candidate.lowercased()) {
            number += 1
            let suffix = " (\(number))"
            candidate = String(base.prefix(Self.maximumSheetNameLength - suffix.count)) + suffix
        }
        takenSheetNames.insert(candidate.lowercased())
        return candidate
    }

    private func sanitizeSheetName(_ name: String) -> String {
        var sanitized = name
        let invalid: [Character] = ["\\", "/", "?", "*", "[", "]", ":"]
        sanitized = String(sanitized.filter { !invalid.contains($0) })
        if sanitized.count > Self.maximumSheetNameLength {
            sanitized = String(sanitized.prefix(Self.maximumSheetNameLength))
        }
        if sanitized.isEmpty {
            sanitized = "Sheet"
        }
        return sanitized
    }
}

// MARK: - Data XML Helpers

private extension Data {
    /// Append a UTF-8 string directly to Data (O(1) amortized, no intermediate String copies)
    mutating func appendUTF8(_ string: String) {
        string.utf8.withContiguousStorageIfAvailable { buffer in
            if let baseAddress = buffer.baseAddress {
                self.append(baseAddress, count: buffer.count)
            }
        } ?? self.append(contentsOf: string.utf8)
    }

    /// Append XML-escaped text directly to Data without creating intermediate Strings.
    /// Strips XML 1.0 illegal control characters (0x00–0x08, 0x0B, 0x0C, 0x0E–0x1F)
    /// that can appear in binary/hex database columns and would produce malformed XML.
    mutating func appendXMLEscaped(_ text: String) {
        for byte in text.utf8 {
            switch byte {
            case 0x26: // &
                append(contentsOf: [0x26, 0x61, 0x6D, 0x70, 0x3B]) // &amp;
            case 0x3C: // <
                append(contentsOf: [0x26, 0x6C, 0x74, 0x3B]) // &lt;
            case 0x3E: // >
                append(contentsOf: [0x26, 0x67, 0x74, 0x3B]) // &gt;
            case 0x22: // "
                append(contentsOf: [0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B]) // &quot;
            case 0x27: // '
                append(contentsOf: [0x26, 0x61, 0x70, 0x6F, 0x73, 0x3B]) // &apos;
            case 0x0D: // A raw CR reads back as LF under XML end-of-line handling
                append(contentsOf: [0x26, 0x23, 0x31, 0x33, 0x3B]) // &#13;
            case 0x09, 0x0A: // Tab and LF are allowed in XML 1.0
                append(byte)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: // Illegal XML 1.0 control chars
                break // Strip silently
            default:
                append(byte)
            }
        }
    }
}

// MARK: - ZIP File Builder

/// Minimal ZIP file builder (store-only, no compression)
private struct ZipFileEntry {
    let path: String
    let data: Data
}

private enum ZipBuilder {
    enum ZipError: LocalizedError {
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                return "XLSX file exceeds 4 GB ZIP limit"
            }
        }
    }

    static func build(entries: [ZipFileEntry]) throws -> Data {
        var totalSize = 22
        for entry in entries {
            let pathLen = entry.path.utf8.count
            totalSize += 30 + pathLen + entry.data.count
            totalSize += 46 + pathLen
        }

        var output = Data(capacity: totalSize)
        var centralDirectory = Data()
        var offsets: [Int] = []

        for entry in entries {
            let currentOffset = output.count
            guard currentOffset <= UInt32.max, entry.data.count <= UInt32.max else {
                throw ZipError.fileTooLarge
            }
            offsets.append(currentOffset)

            let pathData = Data(entry.path.utf8)
            let crc = zlibCRC32(entry.data)

            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.appendUInt16(10)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(crc)
            output.appendUInt32(UInt32(entry.data.count))
            output.appendUInt32(UInt32(entry.data.count))
            output.appendUInt16(UInt16(pathData.count))
            output.appendUInt16(0)
            output.append(pathData)
            output.append(entry.data)

            centralDirectory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(10)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(UInt32(entry.data.count))
            centralDirectory.appendUInt32(UInt32(entry.data.count))
            centralDirectory.appendUInt16(UInt16(pathData.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(UInt32(currentOffset))
            centralDirectory.append(pathData)
        }

        let centralDirOffset = output.count
        guard centralDirOffset <= UInt32.max else {
            throw ZipError.fileTooLarge
        }
        output.append(centralDirectory)

        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(UInt32(centralDirectory.count))
        output.appendUInt32(UInt32(centralDirOffset))
        output.appendUInt16(0)

        return output
    }

    /// CRC-32 using system zlib (hardware-accelerated)
    private static func zlibCRC32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, ptr.assumingMemoryBound(to: UInt8.self), uInt(buffer.count)))
        }
    }
}

// MARK: - Data Extensions for ZIP

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var val = value.littleEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var val = value.littleEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }
}
