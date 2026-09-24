import Foundation
@testable import TableProTabularIO
import XCTest

final class ZipArchiveTests: XCTestCase {
    private func archive(_ files: [(String, String, TestZipBuilder.Method)], configure: (inout TestZipBuilder) -> Void = { _ in }) throws -> ZipArchive {
        var builder = TestZipBuilder()
        configure(&builder)
        for (path, body, method) in files {
            builder.add(path, body, method: method)
        }
        return try ZipArchive(bytes: builder.build())
    }

    func testStoredEntryReadsBackByteForByte() throws {
        let archive = try archive([("a.xml", "<xml>stored</xml>", .stored)])
        XCTAssertEqual(try archive.data(named: "a.xml"), Data("<xml>stored</xml>".utf8))
    }

    func testDeflatedEntryIsInflated() throws {
        let body = String(repeating: "<row>value</row>", count: 5_000)
        let archive = try archive([("b.xml", body, .deflate)])
        XCTAssertEqual(try archive.data(named: "b.xml"), Data(body.utf8))
    }

    func testEveryEntryIsListedWithItsOwnPathAndMethod() throws {
        let archive = try archive([("xl/workbook.xml", "a", .stored), ("xl/worksheets/sheet1.xml", "b", .deflate)])
        XCTAssertEqual(archive.paths, ["xl/workbook.xml", "xl/worksheets/sheet1.xml"])
        XCTAssertEqual(archive.entry(named: "xl/worksheets/sheet1.xml")?.compressionMethod, ZipArchive.deflateMethod)
        XCTAssertEqual(archive.entry(named: "xl/workbook.xml")?.compressionMethod, ZipArchive.storedMethod)
    }

    func testEntryLookupFallsBackToCaseInsensitiveMatch() throws {
        let archive = try archive([("xl/SharedStrings.xml", "a", .stored)])
        XCTAssertNil(archive.entry(named: "xl/sharedStrings.xml"))
        XCTAssertEqual(archive.entry(matching: "xl/sharedStrings.xml")?.path, "xl/SharedStrings.xml")
    }

    func testMissingEntryIsNamedInTheError() throws {
        let archive = try archive([("a.xml", "a", .stored)])
        XCTAssertThrowsError(try archive.data(named: "xl/sharedStrings.xml")) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .entryNotFound("xl/sharedStrings.xml"))
        }
    }

    func testFileThatIsNotAZipIsRefused() {
        XCTAssertThrowsError(try ZipArchive(bytes: Data("not a zip at all".utf8))) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZipArchive)
        }
        XCTAssertThrowsError(try ZipArchive(bytes: Data())) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZipArchive)
        }
    }

    func testEmptyEntryReadsAsEmpty() throws {
        let archive = try archive([("empty.xml", "", .stored), ("empty-deflate.xml", "", .deflate)])
        XCTAssertTrue(try archive.data(named: "empty.xml").isEmpty)
        XCTAssertTrue(try archive.data(named: "empty-deflate.xml").isEmpty)
    }

    func testSizesDeferredToADataDescriptorAreReadFromTheDirectory() throws {
        let body = String(repeating: "<c><v>1</v></c>", count: 2_000)
        let archive = try archive([("sheet.xml", body, .deflate), ("plain.xml", "plain", .stored)]) { builder in
            builder.usesDataDescriptors = true
        }
        XCTAssertEqual(try archive.data(named: "sheet.xml"), Data(body.utf8))
        XCTAssertEqual(try archive.data(named: "plain.xml"), Data("plain".utf8))
    }

    func testZip64ExtraFieldSuppliesSizesAndOffset() throws {
        let body = String(repeating: "x", count: 10_000)
        let archive = try archive([("first.xml", "first", .stored), ("second.xml", body, .deflate)]) { builder in
            builder.usesZip64Extra = true
        }
        let entry = try XCTUnwrap(archive.entry(named: "second.xml"))
        XCTAssertEqual(entry.uncompressedSize, 10_000)
        XCTAssertEqual(try archive.data(for: entry), Data(body.utf8))
        XCTAssertEqual(try archive.data(named: "first.xml"), Data("first".utf8))
    }

    func testOutOfRangeZip64OffsetIsCorruptRatherThanATrap() throws {
        let archive = try archive([("a.xml", "a", .stored)]) { builder in
            builder.usesZip64Extra = true
            builder.zip64OffsetOverride = 0xFFFF_FFFF_FFFF_FFF0
        }
        XCTAssertEqual(archive.entry(named: "a.xml")?.localHeaderOffset, Int.max)
        XCTAssertThrowsError(try archive.data(named: "a.xml")) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .corruptEntry("a.xml"))
        }
    }

    func testOutOfRangeZip64DirectoryOffsetIsNotAnArchive() {
        var bytes = Data()
        bytes.append(TestZipBuilder.uint32(0x0606_4B50))
        bytes.append(Data(count: 44))
        bytes.append(TestZipBuilder.uint64(UInt64.max))
        bytes.append(TestZipBuilder.uint32(0x0706_4B50))
        bytes.append(TestZipBuilder.uint32(0))
        bytes.append(TestZipBuilder.uint64(0))
        bytes.append(TestZipBuilder.uint32(1))
        bytes.append(TestZipBuilder.uint32(0x0605_4B50))
        bytes.append(Data(count: 12))
        bytes.append(TestZipBuilder.uint32(0xFFFF_FFFF))
        bytes.append(TestZipBuilder.uint16(0))
        XCTAssertThrowsError(try ZipArchive(bytes: bytes)) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZipArchive)
        }
    }

    func testUnsupportedCompressionMethodIsReported() throws {
        let archive = try archive([("odd.xml", "odd", .unsupported)])
        XCTAssertThrowsError(try archive.data(named: "odd.xml")) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .unsupportedCompression(14))
        }
    }

    func testTruncatedDeflateStreamIsCorrupt() throws {
        var builder = TestZipBuilder()
        builder.add("sheet.xml", String(repeating: "abcdefgh", count: 4_000), method: .deflate)
        var bytes = builder.build()
        let archive = try ZipArchive(bytes: bytes)
        let entry = try XCTUnwrap(archive.entry(named: "sheet.xml"))
        let payloadStart = entry.localHeaderOffset + 30 + "sheet.xml".utf8.count
        let payloadEnd = payloadStart + entry.compressedSize
        for index in (payloadEnd - entry.compressedSize / 2)..<payloadEnd {
            bytes[index] = 0xFF
        }
        let damaged = try ZipArchive(bytes: bytes)
        XCTAssertThrowsError(try damaged.data(named: "sheet.xml")) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .corruptEntry("sheet.xml"))
        }
    }

    func testStreamingReaderDeliversTheWholeEntryInChunks() throws {
        let body = (0..<20_000).map { "<v>\($0)</v>" }.joined()
        let archive = try archive([("sheet.xml", body, .deflate)])
        let entry = try XCTUnwrap(archive.entry(named: "sheet.xml"))
        var collected = Data()
        var fractions: [Double] = []
        try archive.withReader(for: entry) { reader in
            let chunk = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 4_096)
            defer { chunk.deallocate() }
            while true {
                let produced = try reader.read(into: chunk)
                guard produced > 0, let base = chunk.baseAddress else { break }
                collected.append(base, count: produced)
                fractions.append(reader.fractionConsumed)
            }
        }
        XCTAssertEqual(collected, Data(body.utf8))
        XCTAssertGreaterThan(fractions.count, 1)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(fractions.last, 1)
    }

    func testLocalizedDescriptionsNameTheEntry() {
        XCTAssertEqual(ZipArchive.Failure.entryNotFound("xl/workbook.xml").errorDescription, "The workbook is missing xl/workbook.xml.")
        XCTAssertEqual(ZipArchive.Failure.corruptEntry("a.xml").errorDescription, "Could not read a.xml from the workbook.")
    }
}
