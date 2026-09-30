import Foundation
@testable import TableProTabularIO
import XCTest

final class TabularTextTranscoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabularTextTranscoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func encoded(_ text: String, _ encoding: TabularTextEncoding) throws -> Data {
        try XCTUnwrap(text.data(using: encoding.foundationEncoding, allowLossyConversion: false))
    }

    private func transcode(_ data: Data, _ encoding: TabularTextEncoding, prefix: Int = 0) throws -> (String, TabularTranscodedText) {
        let url = directory.appendingPathComponent(UUID().uuidString)
        let result = try TabularTextTranscoder.transcode(data, from: encoding, skippingPrefix: prefix, to: url)
        return (TabularTextCodec.utf8String(try Data(contentsOf: url)), result)
    }

    func testShiftJISBecomesTheSameTextInUTF8() throws {
        let text = "id,名前\r\n1,髙橋 ①\r\n2,ｻﾞｲｺ ～\r\n"
        let (output, result) = try transcode(try encoded(text, .shiftJIS), .shiftJIS)
        XCTAssertEqual(output, text)
        XCTAssertEqual(result.undecodableLineCount, 0)
    }

    func testABadByteSpoilsOnlyItsOwnLine() throws {
        var bytes = try encoded("a,髙橋\n", .shiftJIS)
        bytes.append(contentsOf: Array("b,".utf8) + [0x82] + Array("\nc,".utf8) + [0xA0] + Array("x\n".utf8))
        bytes.append(try encoded("d,東京\ne,大阪\n", .shiftJIS))
        let (output, result) = try transcode(bytes, .shiftJIS)
        XCTAssertEqual(output, "a,髙橋\nb,\u{FFFD}\nc,\u{FFFD}x\nd,東京\ne,大阪\n")
        XCTAssertEqual(result.undecodableLineCount, 2)
    }

    func testLinesSplitAcrossChunksMatchAWholeFileDecode() throws {
        let line = "10001,東京都港区芝公園４－２－８,ｻﾞｲｺｶﾝﾘｽﾙ,髙橋\r\n"
        let text = String(repeating: line, count: 60_000)
        let bytes = try encoded(text, .shiftJIS)
        XCTAssertGreaterThan(bytes.count, TabularTextTranscoder.chunkLength * 2)
        let (output, result) = try transcode(bytes, .shiftJIS)
        XCTAssertEqual(output, text)
        XCTAssertGreaterThan(result.map.transcodedStarts.count, 2)
        XCTAssertEqual(result.map.transcodedStarts.count, result.map.originalStarts.count)
    }

    func testALineLongerThanAChunkIsCutAtACharacterBoundary() throws {
        let field = String(repeating: "東京都港区芝公園４－２－８ ", count: 90_000)
        let text = "id,memo\n1," + field + "\n2,x\n"
        let bytes = try encoded(text, .shiftJIS)
        XCTAssertGreaterThan(bytes.count, TabularTextTranscoder.chunkLength * 2)
        let (output, result) = try transcode(bytes, .shiftJIS)
        XCTAssertEqual(output, text)
        XCTAssertEqual(result.undecodableLineCount, 0)
        XCTAssertGreaterThan(result.map.transcodedStarts.count, 2)
    }

    func testABrokenLineLongerThanAChunkIsCountedOnce() throws {
        let piece = try encoded(String(repeating: "東京都港区芝公園 ", count: 5_000), .shiftJIS)
        var bytes = try encoded("id,memo\n1,", .shiftJIS)
        for _ in 0..<30 {
            bytes.append(piece)
            bytes.append(0xA0)
        }
        bytes.append(contentsOf: Array("\n2,x\n".utf8))
        XCTAssertGreaterThan(bytes.count, TabularTextTranscoder.chunkLength * 2)
        let (output, result) = try transcode(bytes, .shiftJIS)
        XCTAssertEqual(result.undecodableLineCount, 1)
        XCTAssertEqual(result.firstUndecodableLine, 2)
        XCTAssertTrue(output.hasSuffix("\n2,x\n"))
    }

    func testAMalformedEUCJPByteKeepsTheDelimiterAfterIt() throws {
        let bytes = Data(Array("1,".utf8) + [0x8E] + Array(",x\n\"a".utf8) + [0xA4] + Array("\",b\n".utf8))
        let (output, result) = try transcode(bytes, .eucJP)
        XCTAssertEqual(output, "1,\u{FFFD},x\n\"a\u{FFFD}\",b\n")
        XCTAssertEqual(result.undecodableLineCount, 2)
    }

    func testTheFirstUndecodableLineIsNumberedFromOne() throws {
        var bytes = try encoded("a\r\nb\r\nc\r\n", .shiftJIS)
        bytes.append(contentsOf: [0x64, 0xA0, 0x0D, 0x0A])
        let (_, result) = try transcode(bytes, .shiftJIS)
        XCTAssertEqual(result.firstUndecodableLine, 4)
        XCTAssertNil(try transcode(try encoded("a\nb\n", .shiftJIS), .shiftJIS).1.firstUndecodableLine)
    }

    func testTheFirstInvalidUTF8LineIsFound() {
        let bytes = Data("a,b\nMüller,1\n".utf8) + Data([0x43, 0x61, 0x66, 0xE9, 0x0A]) + Data("z\n".utf8)
        XCTAssertEqual(TabularTextTranscoder.firstInvalidUTF8Line(in: bytes, skippingPrefix: 0), 3)
        XCTAssertNil(TabularTextTranscoder.firstInvalidUTF8Line(in: Data("a\nÜ\n".utf8), skippingPrefix: 0))
    }

    func testCarriageReturnOnlyLinesKeepTheirBreaks() throws {
        let text = "a,日本\rb,中文\rc,한국\r"
        let (output, _) = try transcode(try encoded(text, .utf16LittleEndian), .utf16LittleEndian)
        XCTAssertEqual(output, text)
    }

    func testByteOrderMarkIsSkipped() throws {
        let text = "a,本\n"
        let bytes = Data([0xFF, 0xFE]) + (try encoded(text, .utf16LittleEndian))
        let (output, result) = try transcode(bytes, .utf16LittleEndian, prefix: 2)
        XCTAssertEqual(output, text)
        XCTAssertEqual(result.map.originalStarts.first, 2)
    }

    func testAnOddTrailingUTF16ByteBecomesAReplacementCharacter() throws {
        let bytes = (try encoded("a,b\n日本", .utf16LittleEndian)) + Data([0x41])
        let (output, result) = try transcode(bytes, .utf16LittleEndian)
        XCTAssertEqual(output, "a,b\n日本\u{FFFD}")
        XCTAssertEqual(result.undecodableLineCount, 1)
    }

    func testWindows1252UsesTheCodecsOwnTable() throws {
        let (output, result) = try transcode(Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x80, 0x81, 0x0A]), .windows1252)
        XCTAssertEqual(output, "Café €\u{81}\n")
        XCTAssertEqual(result.undecodableLineCount, 0)
    }

    func testAPrefixEndsOnTheLastWholeLine() throws {
        let text = "a,日本\nb,中文\nc,한국\n"
        let bytes = try encoded(text, .utf16BigEndian)
        let firstTwoLines = try encoded("a,日本\nb,中文\n", .utf16BigEndian).count
        let prefix = try TabularTextTranscoder.utf8Data(
            from: bytes,
            encoding: .utf16BigEndian,
            skippingPrefix: 0,
            wholeLinesWithin: firstTwoLines + 3
        )
        XCTAssertEqual(TabularTextCodec.utf8String(prefix.data), "a,日本\nb,中文\n")
        XCTAssertEqual(prefix.undecodableLineCount, 0)
    }

    func testCancellationStopsTheTranscode() throws {
        let bytes = try encoded(String(repeating: "東京,大阪\n", count: 200_000), .shiftJIS)
        let url = directory.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try TabularTextTranscoder.transcode(bytes, from: .shiftJIS, skippingPrefix: 0, to: url, isCancelled: { true })) {
            XCTAssertTrue($0 is TabularCancellation)
        }
    }
}
