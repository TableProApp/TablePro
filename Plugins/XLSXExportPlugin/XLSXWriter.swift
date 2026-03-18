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

    /// Pre-cached column letter lookups
    private var columnLetterCache: [String] = []

    /// Tracks the current row number for the active sheet being built
    private var currentRowNumber: Int = 0

    /// Whether the current sheet has a header row (used for bold styling)
    private var currentSheetHasHeader: Bool = false

    /// Excel maximum rows per sheet (1,048,576 total including header).
    /// Data rows beyond this limit are silently dropped with a log warning.
    private static let maxRowsPerSheet = 1_048_576

    /// Set to true if any rows were dropped due to the Excel row limit
    private(set) var didTruncateRows = false

    enum CellValue {
        case string(String)
        case number(String)
        case empty
    }

    // MARK: - Sheet Building API

    /// Begin a new worksheet. Must be followed by `addRows` calls and then `finishSheet`.
    func beginSheet(name: String, columns: [String], includeHeader: Bool, convertNullToEmpty: Bool) {
        let sanitized = sanitizeSheetName(name)
        currentRowNumber = 0
        currentSheetHasHeader = includeHeader

        // Pre-cache column letters
        let maxCols = max(columns.count, columnLetterCache.count)
        if maxCols > columnLetterCache.count {
            for i in columnLetterCache.count..<maxCols {
                columnLetterCache.append(columnLetter(i))
            }
        }

        // Start sheet XML with header
        var d = Data()
        d.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        d.appendUTF8("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")

        // Write header row if requested
        if includeHeader {
            let headerCells: [CellValue] = columns.map { .string($0) }
            appendRow(headerCells, isHeader: true, to: &d)
        }

        sheets.append((name: sanitized, data: d))
    }

    /// Add a batch of raw rows to the current (last) sheet.
    /// Converts `[String?]` to `CellValue` and writes XML immediately,
    /// so the caller can release the raw row data after this call returns.
    func addRows(_ rows: [[String?]], convertNullToEmpty: Bool) {
        guard !sheets.isEmpty else { return }

        var sheetData = sheets[sheets.count - 1].data

        for row in rows {
            // Enforce Excel row limit (1,048,576 rows including header)
            if currentRowNumber >= Self.maxRowsPerSheet {
                if !didTruncateRows {
                    didTruncateRows = true
                    Self.logger.warning(
                        "Sheet row limit reached (\(Self.maxRowsPerSheet)). Remaining rows will be dropped."
                    )
                }
                break
            }

            // autoreleasepool frees intermediate strings (cell value conversions)
            // each iteration, preventing peak memory growth during large exports.
            autoreleasepool {
                let cellRow: [CellValue] = row.map { value in
                    guard let val = value else {
                        return convertNullToEmpty ? .empty : .string("NULL")
                    }
                    if val.isEmpty {
                        return .empty
                    }
                    // Try to detect numeric values
                    if Double(val) != nil, !val.hasPrefix("0") || val == "0" || val.contains(".") {
                        return .number(val)
                    }
                    return .string(val)
                }
                appendRow(cellRow, isHeader: false, to: &sheetData)
            }
        }

        sheets[sheets.count - 1].data = sheetData
    }

    /// Finish the current sheet by closing the XML tags.
    func finishSheet() {
        guard !sheets.isEmpty else { return }
        sheets[sheets.count - 1].data.appendUTF8("</sheetData></worksheet>")
    }

    // MARK: - Legacy Convenience API

    /// Add a complete worksheet with all rows at once (legacy compatibility).
    /// For better memory usage, prefer `beginSheet` / `addRows` / `finishSheet`.
    func addSheet(name: String, columns: [String], rows: [[String?]], includeHeader: Bool, convertNullToEmpty: Bool) {
        beginSheet(name: name, columns: columns, includeHeader: includeHeader, convertNullToEmpty: convertNullToEmpty)
        addRows(rows, convertNullToEmpty: convertNullToEmpty)
        finishSheet()
    }

    /// Write the XLSX file to the given URL
    func write(to url: URL) throws {
        // Create ZIP entries
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

        let zipData = ZipBuilder.build(entries: entries)
        try zipData.write(to: url)
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
        d.appendUTF8("</cellXfs></styleSheet>")
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

    private func sanitizeSheetName(_ name: String) -> String {
        var sanitized = name
        let invalid: [Character] = ["\\", "/", "?", "*", "[", "]", ":"]
        sanitized = String(sanitized.filter { !invalid.contains($0) })
        if sanitized.count > 31 {
            sanitized = String(sanitized.prefix(31))
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

    /// Append XML-escaped text directly to Data without creating intermediate Strings
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
    static func build(entries: [ZipFileEntry]) -> Data {
        // Pre-calculate total size for single allocation
        var totalSize = 22 // End of central directory
        for entry in entries {
            let pathLen = entry.path.utf8.count
            totalSize += 30 + pathLen + entry.data.count  // Local file header + data
            totalSize += 46 + pathLen                       // Central directory entry
        }

        var output = Data(capacity: totalSize)
        var centralDirectory = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            offsets.append(UInt32(output.count))

            let pathData = Data(entry.path.utf8)
            let crc = zlibCRC32(entry.data)

            // Local file header
            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])  // Signature
            output.appendUInt16(20)                                 // Version needed
            output.appendUInt16(0)                                  // Flags
            output.appendUInt16(0)                                  // Compression: stored
            output.appendUInt16(0)                                  // Mod time
            output.appendUInt16(0)                                  // Mod date
            output.appendUInt32(crc)                                // CRC-32
            output.appendUInt32(UInt32(entry.data.count))           // Compressed size
            output.appendUInt32(UInt32(entry.data.count))           // Uncompressed size
            output.appendUInt16(UInt16(pathData.count))             // File name length
            output.appendUInt16(0)                                  // Extra field length
            output.append(pathData)
            output.append(entry.data)

            // Central directory entry
            centralDirectory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
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
            centralDirectory.appendUInt32(offsets.last ?? 0)
            centralDirectory.append(pathData)
        }

        let centralDirOffset = UInt32(output.count)
        output.append(centralDirectory)

        // End of central directory
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(UInt32(centralDirectory.count))
        output.appendUInt32(centralDirOffset)
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
