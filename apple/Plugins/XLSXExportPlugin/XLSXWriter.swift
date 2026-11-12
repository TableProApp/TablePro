//
//  XLSXWriter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import zlib

// Each sheet's XML goes to its own file as rows arrive, and `write(to:)` copies those files into a
// stored ZIP, so no sheet is ever held in memory whole. Strings are inline (`t="inlineStr"`), so
// there is no shared string table to grow with the data either.
final class XLSXWriter {
    static let defaultFlushThreshold = 1 << 20
    static let partsDirectoryPrefix = "TablePro-XLSX-"

    private static let logger = Logger(subsystem: "com.TablePro", category: "XLSXWriter")

    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private var sheets: [XLSXSheetPart] = []
    private var sheetBytesInArchive = 0
    private var partsDirectory: URL?
    private var partsLock: Int32?
    private let flushThreshold: Int
    private let maximumArchiveSize: Int

    private static let maximumSheetNameLength = 31
    private var takenSheetNames: Set<String> = []

    private var columnLetterCache: [String] = []

    private var currentRowNumber: Int = 0

    enum CellValue: Equatable {
        case string(String)
        case number(String)
        case empty
    }

    typealias ColumnNumbers = PluginColumnNumbers

    // Excel keeps 15 significant digits of a number.
    private static let maximumExactDigits = 15

    private var currentColumnNumbers: [ColumnNumbers] = []

    private let bitsAreStrings: Bool

    // A sheet holds at most `flushThreshold` bytes plus one row in memory before they go to its file.
    // `maximumArchiveSize` is the ZIP's 4 GB offset limit, checked as the sheets grow.
    init(
        databaseTypeId: String = "",
        partsDirectory: URL? = nil,
        flushThreshold: Int = XLSXWriter.defaultFlushThreshold,
        maximumArchiveSize: Int = Int(UInt32.max)
    ) {
        bitsAreStrings = ColumnNumbers.bitsAreStrings(databaseTypeId: databaseTypeId)
        self.partsDirectory = partsDirectory
        self.flushThreshold = max(0, flushThreshold)
        self.maximumArchiveSize = min(maximumArchiveSize, Int(UInt32.max))
    }

    deinit {
        sheets.forEach { $0.closeWithoutWriting() }
        defer {
            if let partsLock { close(partsLock) }
        }
        guard let partsDirectory else { return }
        do {
            try FileManager.default.removeItem(at: partsDirectory)
        } catch {
            guard (error as? CocoaError)?.code != .fileNoSuchFile else { return }
            Self.logger.warning("Could not remove the workbook's sheet files: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Sheet Building API

    func beginSheet(
        name: String,
        columns: [String],
        columnTypeNames: [String] = [],
        includeHeader: Bool,
        convertNullToEmpty: Bool
    ) throws {
        if let previous = sheets.last, previous.isOpen {
            try closeSheet(previous)
        }
        let sheetName = unusedSheetName(for: name)
        currentColumnNumbers = columnTypeNames.map { ColumnNumbers(typeName: $0, bitsAreStrings: bitsAreStrings) }
        currentRowNumber = 0

        let maxCols = max(columns.count, columnLetterCache.count)
        if maxCols > columnLetterCache.count {
            for i in columnLetterCache.count..<maxCols {
                columnLetterCache.append(columnLetter(i))
            }
        }

        let part = try XLSXSheetPart(name: sheetName, fileURL: try partURL(forSheet: sheets.count + 1))
        sheets.append(part)
        sheetBytesInArchive += ZipBuilder.localHeaderSize(path: Self.sheetPath(sheets.count))
        part.pending.appendUTF8("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        part.pending.appendUTF8("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")

        if includeHeader {
            let headerCells: [CellValue] = columns.map { .string($0) }
            appendRow(headerCells, isHeader: true, to: &part.pending)
        }
        try flush(part)
    }

    // Writes each row's XML as it converts it, so the caller can release the rows once this returns.
    func addRows(_ rows: [[PluginCellValue]], convertNullToEmpty: Bool) throws {
        guard let part = sheets.last, part.isOpen else { return }

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
                appendRow(cellRow, isHeader: false, to: &part.pending)
            }
            try flush(part)
        }
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
        @unknown default:
            return .string(text)
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

    func finishSheet() throws {
        guard let part = sheets.last, part.isOpen else { return }
        part.pending.appendUTF8("</sheetData></worksheet>")
        try closeSheet(part)
    }

    // Finishes the current sheet and starts "BaseName (N)" with the same columns.
    func continueSheet(
        baseName: String,
        columns: [String],
        columnTypeNames: [String] = [],
        includeHeader: Bool,
        convertNullToEmpty: Bool
    ) throws {
        try finishSheet()
        try beginSheet(
            name: baseName,
            columns: columns,
            columnTypeNames: columnTypeNames,
            includeHeader: includeHeader,
            convertNullToEmpty: convertNullToEmpty
        )
    }

    func write(to url: URL) async throws {
        if let part = sheets.last, part.isOpen {
            try closeSheet(part)
        }
        let entries = archiveEntries()
        let maximumSize = maximumArchiveSize
        try await Task.detached(priority: .userInitiated) {
            try ZipBuilder.write(entries, to: url, maximumSize: maximumSize)
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
                path: Self.sheetPath(index + 1),
                file: sheet.fileURL,
                size: sheet.byteCount,
                crc: sheet.crc
            ))
        }

        return entries
    }

    private static func sheetPath(_ number: Int) -> String {
        "xl/worksheets/sheet\(number).xml"
    }

    // MARK: - Sheet Files

    private func partURL(forSheet number: Int) throws -> URL {
        try openPartsDirectory().appendingPathComponent("sheet\(number).xml")
    }

    // The folder stays locked while this writer lives, which tells a later export's sweep that it is in use.
    private func openPartsDirectory() throws -> URL {
        if let partsDirectory, partsLock != nil { return partsDirectory }
        let directory: URL
        if let partsDirectory {
            directory = partsDirectory
        } else {
            let parent = FileManager.default.temporaryDirectory
            Self.removeAbandonedPartsDirectories(in: parent, modifiedBefore: Self.processStart)
            directory = parent.appendingPathComponent(Self.partsDirectoryPrefix + UUID().uuidString, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        partsDirectory = directory
        partsLock = try Self.lock(directory)
        return directory
    }

    // A crash or a force quit skips the deinit that removes a writer's folder. A folder older than
    // this process that no writer holds, in this process or another, was left that way.
    static func removeAbandonedPartsDirectories(in parent: URL, modifiedBefore cutoff: Date) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: Array(keys)
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(partsDirectoryPrefix) {
            guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true,
                  let modified = values.contentModificationDate, modified < cutoff,
                  let descriptor = try? lock(entry) else { continue }
            try? FileManager.default.removeItem(at: entry)
            close(descriptor)
        }
    }

    // `flock` is released when the descriptor closes, also when the process dies.
    private static func lock(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
        return descriptor
    }

    private func flush(_ part: XLSXSheetPart) throws {
        guard part.pending.count >= flushThreshold else { return }
        try account(writtenBytes: part.writePending())
    }

    private func closeSheet(_ part: XLSXSheetPart) throws {
        try account(writtenBytes: part.close())
    }

    // The sheets alone already past the limit means `write(to:)` would refuse the archive, so the
    // export stops now instead of after reading every remaining row.
    private func account(writtenBytes: Int) throws {
        sheetBytesInArchive += writtenBytes
        guard sheetBytesInArchive <= maximumArchiveSize else { throw ZipBuilder.ZipError.fileTooLarge }
    }

    // MARK: - Row XML Generation

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

    // MARK: - XML Generation

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
    mutating func appendUTF8(_ string: String) {
        string.utf8.withContiguousStorageIfAvailable { buffer in
            if let baseAddress = buffer.baseAddress {
                self.append(baseAddress, count: buffer.count)
            }
        } ?? self.append(contentsOf: string.utf8)
    }

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

// MARK: - Sheet Part

private final class XLSXSheetPart {
    let name: String
    let fileURL: URL
    var pending = Data()
    private var handle: FileHandle?
    private(set) var byteCount = 0
    private(set) var crc: UInt32 = 0

    var isOpen: Bool { handle != nil }

    init(name: String, fileURL: URL) throws {
        self.name = name
        self.fileURL = fileURL
        guard FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: fileURL])
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    func writePending() throws -> Int {
        guard let handle, !pending.isEmpty else { return 0 }
        try handle.write(contentsOf: pending)
        crc = ZipBuilder.crc32(of: pending, continuing: crc)
        let written = pending.count
        byteCount += written
        pending.removeAll(keepingCapacity: true)
        return written
    }

    func close() throws -> Int {
        guard let handle else { return 0 }
        let written = try writePending()
        self.handle = nil
        try handle.close()
        return written
    }

    func closeWithoutWriting() {
        try? handle?.close()
        handle = nil
    }
}

// MARK: - ZIP File Builder

// A stored (uncompressed) ZIP, written entry by entry. A sheet's bytes are copied from its file.
private struct ZipFileEntry {
    enum Contents {
        case data(Data)
        case file(URL)
    }

    let path: String
    let contents: Contents
    let size: Int
    let crc: UInt32

    init(path: String, data: Data) {
        self.path = path
        contents = .data(data)
        size = data.count
        crc = ZipBuilder.crc32(of: data)
    }

    init(path: String, file: URL, size: Int, crc: UInt32) {
        self.path = path
        contents = .file(file)
        self.size = size
        self.crc = crc
    }
}

private enum ZipBuilder {
    enum ZipError: LocalizedError {
        case fileTooLarge
        case tooManySheets

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                return String(localized: "XLSX file exceeds 4 GB ZIP limit")
            case .tooManySheets:
                return String(localized: "The workbook has more sheets than an XLSX file can hold.")
            }
        }
    }

    private static let copyChunkSize = 1 << 20

    static func localHeaderSize(path: String) -> Int {
        30 + path.utf8.count
    }

    static func write(_ entries: [ZipFileEntry], to destination: URL, maximumSize: Int) throws {
        var offsets: [Int] = []
        offsets.reserveCapacity(entries.count)
        var offset = 0
        for entry in entries {
            guard offset <= maximumSize, entry.size <= maximumSize else {
                throw ZipError.fileTooLarge
            }
            offsets.append(offset)
            offset += localHeaderSize(path: entry.path) + entry.size
        }
        guard offset <= maximumSize else {
            throw ZipError.fileTooLarge
        }
        guard entries.count <= Int(UInt16.max) else {
            throw ZipError.tooManySheets
        }

        let (handle, temporaryURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var isOpen = true
        do {
            var centralDirectory = Data()
            for (entry, entryOffset) in zip(entries, offsets) {
                let pathData = Data(entry.path.utf8)

                var header = Data()
                header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
                header.appendUInt16(10)
                header.appendUInt16(0)
                header.appendUInt16(0)
                header.appendUInt16(0)
                header.appendUInt16(0)
                header.appendUInt32(entry.crc)
                header.appendUInt32(UInt32(entry.size))
                header.appendUInt32(UInt32(entry.size))
                header.appendUInt16(UInt16(pathData.count))
                header.appendUInt16(0)
                header.append(pathData)
                try handle.write(contentsOf: header)
                try writeContents(of: entry, to: handle)

                centralDirectory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
                centralDirectory.appendUInt16(20)
                centralDirectory.appendUInt16(10)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt32(entry.crc)
                centralDirectory.appendUInt32(UInt32(entry.size))
                centralDirectory.appendUInt32(UInt32(entry.size))
                centralDirectory.appendUInt16(UInt16(pathData.count))
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt16(0)
                centralDirectory.appendUInt32(0)
                centralDirectory.appendUInt32(UInt32(entryOffset))
                centralDirectory.append(pathData)
            }

            var end = Data()
            end.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
            end.appendUInt16(0)
            end.appendUInt16(0)
            end.appendUInt16(UInt16(entries.count))
            end.appendUInt16(UInt16(entries.count))
            end.appendUInt32(UInt32(centralDirectory.count))
            end.appendUInt32(UInt32(offset))
            end.appendUInt16(0)

            try handle.write(contentsOf: centralDirectory)
            try handle.write(contentsOf: end)
            isOpen = false
            try handle.close()
            try PluginExportUtilities.commitAtomicWrite(from: temporaryURL, to: destination)
        } catch {
            if isOpen {
                try? handle.close()
            }
            PluginExportUtilities.rollbackAtomicWrite(at: temporaryURL)
            throw error
        }
    }

    private static func writeContents(of entry: ZipFileEntry, to handle: FileHandle) throws {
        switch entry.contents {
        case .data(let data):
            try handle.write(contentsOf: data)
        case .file(let url):
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            var copied = 0
            while true {
                let chunk = try autoreleasepool { try reader.read(upToCount: copyChunkSize) } ?? Data()
                guard !chunk.isEmpty else { break }
                try handle.write(contentsOf: chunk)
                copied += chunk.count
            }
            // The header already promised this size and CRC.
            guard copied == entry.size else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
            }
        }
    }

    static func crc32(of data: Data, continuing crc: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress, !buffer.isEmpty else { return crc }
            return UInt32(zlib.crc32(uLong(crc), ptr.assumingMemoryBound(to: UInt8.self), uInt(buffer.count)))
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
