import Foundation
@testable import TableProTabularIO
import Testing

struct ZipArchiveTests {
    private func archive(_ files: [(String, String, TestZipBuilder.Method)], configure: (inout TestZipBuilder) -> Void = { _ in }) throws -> ZipArchive {
        var builder = TestZipBuilder()
        configure(&builder)
        for (path, body, method) in files {
            builder.add(path, body, method: method)
        }
        return try ZipArchive(bytes: builder.build())
    }

    @Test func testAnEntryLargerThanTheBufferLimitIsRefusedBeforeInflating() throws {
        let archive = try archive([("xl/styles.xml", String(repeating: "a", count: 4_096), .deflate)])
        let entry = try #require(archive.entry(named: "xl/styles.xml"))
        if let error = #expect(throws: (any Error).self, performing: { try archive.data(for: entry, limit: 1_024) }) {
            #expect(error as? ZipArchive.Failure == .entryTooLarge("xl/styles.xml"))
        }
    }

    @Test func testAnEntryThatInflatesPastItsDeclaredSizeIsRefused() throws {
        var builder = TestZipBuilder()
        builder.add("xl/workbook.xml", String(repeating: "<sheet/>", count: 10_000), method: .deflate)
        var bytes = [UInt8](builder.build())
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let header = try #require((0...(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == signature })
        bytes.replaceSubrange((header + 24)..<(header + 28), with: [0x10, 0x00, 0x00, 0x00])
        let archive = try ZipArchive(bytes: Data(bytes))
        if let error = #expect(throws: (any Error).self, performing: { try archive.data(named: "xl/workbook.xml") }) {
            #expect(error as? ZipArchive.Failure == .corruptEntry("xl/workbook.xml"))
        }
    }

    @Test func testAnEntryThatExpandsFarBeyondItsCompressedSizeIsRefused() throws {
        let policy = ZipExpansionPolicy(ratioLimit: ZipExpansionPolicy.standard.ratioLimit, grace: 1 << 20)
        let body = String(repeating: "A", count: 4 << 20)
        let archive = try archive([("xl/worksheets/sheet1.xml", body, .deflate)])
        let entry = try #require(archive.entry(named: "xl/worksheets/sheet1.xml"))
        #expect(entry.uncompressedSize / max(entry.compressedSize, 1) > policy.ratioLimit)
        #expect(try archive.data(for: entry).count == body.utf8.count)
        if let error = #expect(throws: (any Error).self, performing: { try archive.data(for: entry, policy: policy) }) {
            #expect(error as? ZipArchive.Failure == .entryTooLarge("xl/worksheets/sheet1.xml"))
        }
    }

    @Test func testStoredEntryReadsBackByteForByte() throws {
        let archive = try archive([("a.xml", "<xml>stored</xml>", .stored)])
        #expect(try archive.data(named: "a.xml") == Data("<xml>stored</xml>".utf8))
    }

    @Test func testDeflatedEntryIsInflated() throws {
        let body = String(repeating: "<row>value</row>", count: 5_000)
        let archive = try archive([("b.xml", body, .deflate)])
        #expect(try archive.data(named: "b.xml") == Data(body.utf8))
    }

    @Test func testEveryEntryIsListedWithItsOwnPathAndMethod() throws {
        let archive = try archive([("xl/workbook.xml", "a", .stored), ("xl/worksheets/sheet1.xml", "b", .deflate)])
        #expect(archive.paths == ["xl/workbook.xml", "xl/worksheets/sheet1.xml"])
        #expect(archive.entry(named: "xl/worksheets/sheet1.xml")?.compressionMethod == ZipArchive.deflateMethod)
        #expect(archive.entry(named: "xl/workbook.xml")?.compressionMethod == ZipArchive.storedMethod)
    }

    @Test func testEntryLookupFallsBackToCaseInsensitiveMatch() throws {
        let archive = try archive([("xl/SharedStrings.xml", "a", .stored)])
        #expect(archive.entry(named: "xl/sharedStrings.xml") == nil)
        #expect(archive.entry(matching: "xl/sharedStrings.xml")?.path == "xl/SharedStrings.xml")
    }

    @Test func testMissingEntryIsNamedInTheError() throws {
        let archive = try archive([("a.xml", "a", .stored)])
        if let error = #expect(throws: (any Error).self, performing: { try archive.data(named: "xl/sharedStrings.xml") }) {
            #expect(error as? ZipArchive.Failure == .entryNotFound("xl/sharedStrings.xml"))
        }
    }

    @Test func testFileThatIsNotAZipIsRefused() {
        if let error = #expect(throws: (any Error).self, performing: { try ZipArchive(bytes: Data("not a zip at all".utf8)) }) {
            #expect(error as? ZipArchive.Failure == .notAZipArchive)
        }
        if let error = #expect(throws: (any Error).self, performing: { try ZipArchive(bytes: Data()) }) {
            #expect(error as? ZipArchive.Failure == .notAZipArchive)
        }
    }

    @Test func testEmptyEntryReadsAsEmpty() throws {
        let archive = try archive([("empty.xml", "", .stored), ("empty-deflate.xml", "", .deflate)])
        #expect(try archive.data(named: "empty.xml").isEmpty)
        #expect(try archive.data(named: "empty-deflate.xml").isEmpty)
    }

    @Test func testSizesDeferredToADataDescriptorAreReadFromTheDirectory() throws {
        let body = String(repeating: "<c><v>1</v></c>", count: 2_000)
        let archive = try archive([("sheet.xml", body, .deflate), ("plain.xml", "plain", .stored)]) { builder in
            builder.usesDataDescriptors = true
        }
        #expect(try archive.data(named: "sheet.xml") == Data(body.utf8))
        #expect(try archive.data(named: "plain.xml") == Data("plain".utf8))
    }

    @Test func testZip64ExtraFieldSuppliesSizesAndOffset() throws {
        let body = String(repeating: "x", count: 10_000)
        let archive = try archive([("first.xml", "first", .stored), ("second.xml", body, .deflate)]) { builder in
            builder.usesZip64Extra = true
        }
        let entry = try #require(archive.entry(named: "second.xml"))
        #expect(entry.uncompressedSize == 10_000)
        #expect(try archive.data(for: entry) == Data(body.utf8))
        #expect(try archive.data(named: "first.xml") == Data("first".utf8))
    }

    @Test func testOutOfRangeZip64OffsetIsCorruptRatherThanATrap() throws {
        let archive = try archive([("a.xml", "a", .stored)]) { builder in
            builder.usesZip64Extra = true
            builder.zip64OffsetOverride = 0xFFFF_FFFF_FFFF_FFF0
        }
        #expect(archive.entry(named: "a.xml")?.localHeaderOffset == Int.max)
        if let error = #expect(throws: (any Error).self, performing: { try archive.data(named: "a.xml") }) {
            #expect(error as? ZipArchive.Failure == .corruptEntry("a.xml"))
        }
    }

    @Test func testOutOfRangeZip64DirectoryOffsetIsNotAnArchive() {
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
        if let error = #expect(throws: (any Error).self, performing: { try ZipArchive(bytes: bytes) }) {
            #expect(error as? ZipArchive.Failure == .notAZipArchive)
        }
    }

    @Test func testUnsupportedCompressionMethodIsReported() throws {
        let archive = try archive([("odd.xml", "odd", .unsupported)])
        if let error = #expect(throws: (any Error).self, performing: { try archive.data(named: "odd.xml") }) {
            #expect(error as? ZipArchive.Failure == .unsupportedCompression(14))
        }
    }

    @Test func testTruncatedDeflateStreamIsCorrupt() throws {
        var builder = TestZipBuilder()
        builder.add("sheet.xml", String(repeating: "abcdefgh", count: 4_000), method: .deflate)
        var bytes = builder.build()
        let archive = try ZipArchive(bytes: bytes)
        let entry = try #require(archive.entry(named: "sheet.xml"))
        let payloadStart = entry.localHeaderOffset + 30 + "sheet.xml".utf8.count
        let payloadEnd = payloadStart + entry.compressedSize
        for index in (payloadEnd - entry.compressedSize / 2)..<payloadEnd {
            bytes[index] = 0xFF
        }
        let damaged = try ZipArchive(bytes: bytes)
        if let error = #expect(throws: (any Error).self, performing: { try damaged.data(named: "sheet.xml") }) {
            #expect(error as? ZipArchive.Failure == .corruptEntry("sheet.xml"))
        }
    }

    @Test func testStreamingReaderDeliversTheWholeEntryInChunks() throws {
        let body = (0..<20_000).map { "<v>\($0)</v>" }.joined()
        let archive = try archive([("sheet.xml", body, .deflate)])
        let entry = try #require(archive.entry(named: "sheet.xml"))
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
        #expect(collected == Data(body.utf8))
        #expect(fractions.count > 1)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
    }

    @Test func testLocalizedDescriptionsNameTheEntry() {
        #expect(ZipArchive.Failure.entryNotFound("xl/workbook.xml").errorDescription == "The workbook is missing xl/workbook.xml.")
        #expect(ZipArchive.Failure.corruptEntry("a.xml").errorDescription == "Could not read a.xml from the workbook.")
    }
}
