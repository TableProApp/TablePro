//
//  XLSXWriterStreamingTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
import TableProPluginKit
import TableProTabularIO
import TableProWireIO
import Testing
import zlib

struct XLSXWriterStreamingTests {
    private static let columns = ["id", "name", "score", "blob", "note"]
    private static let columnTypeNames = ["int4", "text", "float8", "bytea", "varchar(8)"]

    // SHA-256 of the workbook below as the stored ZIP TablePro wrote before sheets were deflated; every flush
    // threshold has to produce entries that rebuild it.
    private static let workbookDigest = "0e3615d4591e87affd46978b977d3122f9cf93f459873835a08080ae9048f333"

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-streaming-\(UUID().uuidString)-\(name)")
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return try #require((attributes[.size] as? NSNumber)?.intValue)
    }

    private func buildWorkbook(_ writer: XLSXWriter) throws {
        try writer.beginSheet(
            name: "users", columns: Self.columns, columnTypeNames: Self.columnTypeNames,
            includeHeader: true, convertNullToEmpty: false
        )
        try writer.addRows([
            [.text("1"), .text("Ada & <Lovelace>"), .text("3.5"), .bytes(Data([0xDE, 0xAD])), .null],
            [.text("2"), .text("Grace \"Hopper\"\r\n'x'"), .text("1e-7"), .bytes(Data()), .text("007")],
            [.text("1234567890123456789"), .text(""), .text("NaN"), .null, .text("\u{01}bell")],
        ], convertNullToEmpty: false)
        try writer.continueSheet(
            baseName: "users", columns: Self.columns, columnTypeNames: Self.columnTypeNames,
            includeHeader: true, convertNullToEmpty: false
        )
        try writer.addRows([[.text("3"), .text("Hà Nội 東京"), .text("-0.50"), .null, .text("x")]], convertNullToEmpty: false)
        try writer.finishSheet()
        try writer.beginSheet(name: "Users", columns: ["a", "b"], includeHeader: false, convertNullToEmpty: true)
        try writer.addRows((1...3_000).map { [.text(String($0)), .text("v\($0)")] }, convertNullToEmpty: true)
        try writer.addRows([[.null, .text("1E5")]], convertNullToEmpty: true)
        try writer.finishSheet()
        try writer.beginSheet(name: "a/b:c", columns: [], includeHeader: false, convertNullToEmpty: true)
        try writer.finishSheet()
    }

    // The stored ZIP the writer used to write, rebuilt from the deflated workbook's entries: same order, same
    // headers, method 0.
    private func storedArchive(of contents: XLSXArchiveContents) -> Data {
        func uint16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func uint32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var archive = Data()
        var directory = Data()
        for entry in contents.entries {
            let path = Array(entry.path.utf8)
            let crc = crc32(of: entry.bytes)
            let size = uint32(UInt32(entry.bytes.count))
            let offset = UInt32(archive.count)
            archive.append(contentsOf: [0x50, 0x4B, 0x03, 0x04] + uint16(10) + uint16(0) + uint16(0) + uint16(0) + uint16(0))
            archive.append(contentsOf: uint32(crc) + size + size + uint16(path.count) + uint16(0) + path)
            archive.append(entry.bytes)
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02] + uint16(20) + uint16(10) + uint16(0) + uint16(0))
            directory.append(contentsOf: uint16(0) + uint16(0) + uint32(crc) + size + size + uint16(path.count))
            directory.append(contentsOf: uint16(0) + uint16(0) + uint16(0) + uint16(0) + uint32(0) + uint32(offset) + path)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + uint16(0) + uint16(0))
        archive.append(contentsOf: uint16(contents.entries.count) + uint16(contents.entries.count))
        archive.append(contentsOf: uint32(UInt32(directory.count)) + uint32(directoryOffset) + uint16(0))
        return archive
    }

    private func crc32(of data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
            return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: UInt8.self), uInt(buffer.count)))
        }
    }

    // Each local header's CRC-32 (offset 14) and method (offset 8), read from the file itself.
    private func localHeaders(of data: Data) throws -> [String: (method: UInt16, crc: UInt32)] {
        let archive = try ZipArchive(bytes: data)
        let bytes = [UInt8](data)
        var headers: [String: (method: UInt16, crc: UInt32)] = [:]
        for entry in archive.entries.values {
            let start = entry.localHeaderOffset
            let method = UInt16(bytes[start + 8]) | UInt16(bytes[start + 9]) << 8
            let crc = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + 14 + $1]) << (8 * $1) }
            headers[entry.path] = (method, crc)
        }
        return headers
    }

    @Test(
        "The workbook keeps every byte it had when sheets were stored, in deflated entries",
        arguments: [0, 64, XLSXWriter.defaultFlushThreshold]
    )
    func workbookBytesAreUnchanged(flushThreshold: Int) async throws {
        let destination = temporaryURL("workbook.xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("an older export".utf8).write(to: destination)

        let writer = XLSXWriter(flushThreshold: flushThreshold)
        try buildWorkbook(writer)
        try await writer.write(to: destination)

        let contents = try XLSXArchiveContents(contentsOf: destination)
        let digest = SHA256.hash(data: storedArchive(of: contents)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.workbookDigest)
    }

    @Test("Every entry is deflated, and its header's CRC is the CRC of what it inflates to")
    func entriesAreDeflatedWithTheirCRC() async throws {
        let destination = temporaryURL("workbook.xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = XLSXWriter()
        try buildWorkbook(writer)
        try await writer.write(to: destination)

        let data = try Data(contentsOf: destination)
        let contents = try XLSXArchiveContents(data)
        let headers = try localHeaders(of: data)
        #expect(contents.entries.first?.path == "[Content_Types].xml")
        #expect(contents.entries.count == 9)
        for entry in contents.entries {
            #expect(entry.method == ZipArchive.deflateMethod, "\(entry.path)")
            #expect(headers[entry.path]?.method == ZipArchive.deflateMethod, "\(entry.path)")
            #expect(headers[entry.path]?.crc == crc32(of: entry.bytes), "\(entry.path)")
        }
        let emptySheet = try contents.xml(of: "xl/worksheets/sheet4.xml")
        #expect(emptySheet.hasSuffix("<sheetData></sheetData></worksheet>"))
    }

    @Test("A sheet's XML reaches its file, deflated, while its rows arrive")
    func sheetXMLReachesItsFileAsRowsArrive() throws {
        let parts = temporaryURL("parts")
        let threshold = 4_096
        let writer = XLSXWriter(partsDirectory: parts, flushThreshold: threshold)
        try writer.beginSheet(name: "t", columns: ["a", "b"], includeHeader: true, convertNullToEmpty: true)
        try writer.addRows((1...50_000).map { [.text(String($0)), .text("value \($0)")] }, convertNullToEmpty: true)

        let sheet = parts.appendingPathComponent("sheet1.xml")
        let writtenBeforeFinishing = try fileSize(sheet)
        try writer.finishSheet()
        let sheetSize = try fileSize(sheet)

        // zlib holds back at most a block of output, which this sheet's size dwarfs.
        #expect(sheetSize > 100 * threshold)
        #expect(sheetSize - writtenBeforeFinishing < sheetSize / 4)
    }

    @Test("A sheet of one long value repeated reads back under the import's expansion limit")
    func repetitiveSheetPassesTheImportGuard() async throws {
        let destination = temporaryURL("repeated.xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = XLSXWriter()
        try writer.beginSheet(name: "t", columns: ["v"], includeHeader: true, convertNullToEmpty: true)
        let row: [PluginCellValue] = [.text(String(repeating: "x", count: XLSXWriter.maximumCellLength))]
        for _ in 0..<26 {
            try writer.addRows(Array(repeating: row, count: 100), convertNullToEmpty: true)
        }
        try writer.finishSheet()
        try await writer.write(to: destination)

        let archive = try ZipArchive(contentsOf: destination)
        let entry = try #require(archive.entry(named: "xl/worksheets/sheet1.xml"))
        #expect(entry.uncompressedSize > 80 << 20)
        let produced = try archive.withReader(for: entry, budget: .standard) { reader in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1 << 20)
            defer { buffer.deallocate() }
            var total = 0
            while true {
                let count = try reader.read(into: buffer)
                guard count > 0 else { break }
                total += count
            }
            return total
        }
        #expect(produced == entry.uncompressedSize)

        let sheet = try XLSXImportSheet.read(at: destination, hasHeaderRow: true, isCancelled: { false })
        #expect(sheet.rowCount == 2_600)
    }

    @Test("A sheet past the ZIP size limit fails while its rows are still arriving")
    func oversizedWorkbookFailsEarly() throws {
        let writer = XLSXWriter(flushThreshold: 0, maximumArchiveSize: 20_000)
        try writer.beginSheet(name: "t", columns: ["a"], includeHeader: false, convertNullToEmpty: true)
        var acceptedBatches = 0
        var failure: (any Error)?
        do {
            for _ in 0..<1_000 {
                try writer.addRows((1...100).map { [.text("row \($0)")] }, convertNullToEmpty: true)
                acceptedBatches += 1
            }
        } catch {
            failure = error
        }
        #expect(failure != nil)
        #expect(acceptedBatches < 10)
    }

    @Test("A writer that goes away, as a cancelled export's does, removes its sheet files")
    func abandonedWriterRemovesItsSheetFiles() throws {
        let parts = temporaryURL("parts")
        do {
            let writer = XLSXWriter(partsDirectory: parts, flushThreshold: 0)
            try writer.beginSheet(name: "t", columns: ["a"], includeHeader: true, convertNullToEmpty: true)
            try writer.addRows([[.text("1")]], convertNullToEmpty: true)
            withExtendedLifetime(writer) {
                #expect(FileManager.default.fileExists(atPath: parts.appendingPathComponent("sheet1.xml").path(percentEncoded: false)))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: parts.path(percentEncoded: false)))
    }

    @Test("A new export removes the sheet folders an export that crashed left behind, and only those")
    func abandonedSheetFoldersAreSwept() throws {
        let parent = temporaryURL("temporary")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = { (name: String) in parent.appendingPathComponent(name, isDirectory: true) }
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

        let crashed = folder(XLSXWriter.partsDirectoryPrefix + "crashed")
        let recent = folder(XLSXWriter.partsDirectoryPrefix + "recent")
        let unrelated = folder("unrelated")
        for url in [crashed, recent, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("<row/>".utf8).write(to: crashed.appendingPathComponent("sheet1.xml"))
        let running = folder(XLSXWriter.partsDirectoryPrefix + "running")
        let writer = XLSXWriter(partsDirectory: running)
        try writer.beginSheet(name: "t", columns: ["a"], includeHeader: true, convertNullToEmpty: true)

        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86_400)
        for url in [crashed, unrelated, running] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: url.path(percentEncoded: false))
        }
        XLSXWriter.removeAbandonedPartsDirectories(in: parent, modifiedBefore: Date(timeIntervalSinceNow: -3_600))

        withExtendedLifetime(writer) {
            #expect(!exists(crashed))
            #expect(exists(running))
            #expect(exists(recent))
            #expect(exists(unrelated))
        }
    }
}
