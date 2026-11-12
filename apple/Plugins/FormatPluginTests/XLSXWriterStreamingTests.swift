//
//  XLSXWriterStreamingTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
import TableProPluginKit
import Testing

struct XLSXWriterStreamingTests {
    private static let columns = ["id", "name", "score", "blob", "note"]
    private static let columnTypeNames = ["int4", "text", "float8", "bytea", "varchar(8)"]

    // SHA-256 of the workbook below; every flush threshold has to produce it.
    private static let workbookDigest = "0e3615d4591e87affd46978b977d3122f9cf93f459873835a08080ae9048f333"

    private static let closingTags = "</sheetData></worksheet>".utf8.count

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

    @Test(
        "The workbook keeps every byte it had when sheets were built in memory",
        arguments: [0, 64, XLSXWriter.defaultFlushThreshold]
    )
    func workbookBytesAreUnchanged(flushThreshold: Int) async throws {
        let destination = temporaryURL("workbook.xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("an older export".utf8).write(to: destination)

        let writer = XLSXWriter(flushThreshold: flushThreshold)
        try buildWorkbook(writer)
        try await writer.write(to: destination)

        let digest = SHA256.hash(data: try Data(contentsOf: destination)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.workbookDigest)
    }

    @Test("A sheet holds at most one flush of XML in memory while its rows arrive")
    func sheetXMLReachesItsFileAsRowsArrive() throws {
        let parts = temporaryURL("parts")
        let threshold = 4_096
        let writer = XLSXWriter(partsDirectory: parts, flushThreshold: threshold)
        try writer.beginSheet(name: "t", columns: ["a", "b"], includeHeader: true, convertNullToEmpty: true)
        try writer.addRows((1...10_000).map { [.text(String($0)), .text("value \($0)")] }, convertNullToEmpty: true)

        let sheet = parts.appendingPathComponent("sheet1.xml")
        let writtenBeforeFinishing = try fileSize(sheet)
        try writer.finishSheet()
        let sheetSize = try fileSize(sheet)

        #expect(sheetSize > 100 * threshold)
        #expect(sheetSize - writtenBeforeFinishing < threshold + Self.closingTags)
    }

    @Test("A workbook past the ZIP size limit fails while its rows are still arriving")
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
