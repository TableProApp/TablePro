import Foundation
@testable import TableProTabularIO
import XCTest

final class JSONTableIndexerTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    func testArrayOfObjectsRecordsRowSpansAndKeysInFirstSeenOrder() throws {
        let index = try JSONFixtures.index(#"[{"b":1,"a":2},{"c":3,"a":4}]"#, kind: .json)
        XCTAssertEqual(index.shape, .array)
        XCTAssertEqual(index.rowStarts, [1, 15])
        XCTAssertEqual(index.openingBracket, 0)
        XCTAssertEqual(index.bodyEnd, 28)
        XCTAssertEqual(index.span(ofRow: 0), 1..<15)
        XCTAssertEqual(index.span(ofRow: 1), 15..<28)
        XCTAssertEqual(index.keys, ["b", "a", "c"])
    }

    func testJSONLinesRecordsEachObjectAndTheLineEnding() throws {
        let index = try JSONFixtures.index("{\"a\":1}\r\n\r\n{\"b\":2}\r\n")
        XCTAssertEqual(index.shape, .lines)
        XCTAssertEqual(index.rowStarts, [0, 11])
        XCTAssertEqual(index.span(ofRow: 1), 11..<20)
        XCTAssertEqual(index.lineEnding, .crlf)
        XCTAssertEqual(index.keys, ["a", "b"])
    }

    func testLineEndingDefaultsToLineFeedAndDetectsCarriageReturn() throws {
        XCTAssertEqual(try JSONFixtures.index(#"[{"a":1},{"a":2}]"#, kind: .json).lineEnding, .lf)
        XCTAssertEqual(try JSONFixtures.index("{\"a\":1}\r{\"a\":2}").lineEnding, .cr)
        XCTAssertEqual(try JSONFixtures.index("{\"a\":1}\n{\"a\":2}").lineEnding, .lf)
    }

    func testByteOrderMarkIsSkipped() throws {
        let index = try JSONFixtures.index(JSONByte.utf8ByteOrderMark + Array(#"[{"a":1}]"#.utf8), kind: .json)
        XCTAssertEqual(index.contentStart, 3)
        XCTAssertTrue(index.hasByteOrderMark)
        XCTAssertEqual(index.openingBracket, 3)
        XCTAssertEqual(index.rowStarts, [4])
    }

    func testEmptyOrBlankJSONLinesHasNoRows() throws {
        XCTAssertEqual(try JSONFixtures.index("").rowCount, 0)
        let blank = try JSONFixtures.index("\n \r\n")
        XCTAssertEqual(blank.rowCount, 0)
        XCTAssertEqual(blank.shape, .lines)
        XCTAssertEqual(blank.lineEnding, .lf)
    }

    func testEmptyArrayHasNoRows() throws {
        let index = try JSONFixtures.index("[ ]\n", kind: .json)
        XCTAssertEqual(index.rowCount, 0)
        XCTAssertEqual(index.openingBracket, 0)
        XCTAssertEqual(index.bodyEnd, 2)
        XCTAssertEqual(index.keys, [])
    }

    func testEmptyJSONDocumentThrows() {
        XCTAssertEqual(JSONFixtures.indexError("", kind: .json) as? JSONTableError, .emptyDocument)
        XCTAssertEqual(JSONFixtures.indexError(" \n", kind: .json) as? JSONTableError, .emptyDocument)
    }

    func testSingleTopLevelObjectInJSONFileThrows() {
        XCTAssertEqual(JSONFixtures.indexError("\n  {\"a\":1}\n", kind: .json) as? JSONTableError, .singleObject(byteOffset: 3))
    }

    func testSeveralTopLevelObjectsInJSONFileReadAsLines() throws {
        let index = try JSONFixtures.index("{\"a\":1}\n{\"a\":2}\n", kind: .json)
        XCTAssertEqual(index.shape, .lines)
        XCTAssertEqual(index.rowCount, 2)
    }

    func testObjectsSpanningLinesAndSharingALineAreRows() throws {
        let index = try JSONFixtures.index("{\n  \"a\": 1\n}\n{\"a\":2} {\"b\":3}\n")
        XCTAssertEqual(index.rowStarts, [0, 13, 21])
        XCTAssertEqual(index.keys, ["a", "b"])
    }

    func testScalarDocumentThrows() {
        XCTAssertEqual(JSONFixtures.indexError("42", kind: .json) as? JSONTableError, .scalarDocument(byteOffset: 0))
        XCTAssertEqual(JSONFixtures.indexError(" \"x\"", kind: .json) as? JSONTableError, .scalarDocument(byteOffset: 1))
        XCTAssertEqual(JSONFixtures.indexError("x", kind: .json) as? JSONTableError, .unexpectedByte(row: 0, byteOffset: 0))
    }

    func testLineThatIsNotAnObjectThrows() {
        XCTAssertEqual(JSONFixtures.indexError("42\n") as? JSONTableError, .rowIsNotAnObject(row: 0, byteOffset: 0))
        XCTAssertEqual(JSONFixtures.indexError("{\"a\":1}\n42\n") as? JSONTableError, .rowIsNotAnObject(row: 1, byteOffset: 8))
        XCTAssertEqual(JSONFixtures.indexError("{\"a\":1}\n[1]\n") as? JSONTableError, .rowIsNotAnObject(row: 1, byteOffset: 8))
        XCTAssertEqual(JSONFixtures.indexError("{\"a\":1}\n#\n") as? JSONTableError, .unexpectedByte(row: 1, byteOffset: 8))
    }

    func testArrayElementThatIsNotAnObjectThrows() {
        XCTAssertEqual(
            JSONFixtures.indexError(#"[{"a":1}, 2]"#, kind: .json) as? JSONTableError,
            .rowIsNotAnObject(row: 1, byteOffset: 10)
        )
        XCTAssertEqual(
            JSONFixtures.indexError(#"[[1]]"#, kind: .json) as? JSONTableError,
            .rowIsNotAnObject(row: 0, byteOffset: 1)
        )
    }

    func testTruncatedInputThrows() {
        XCTAssertEqual(JSONFixtures.indexError(#"{"a":1"#) as? JSONTableError, .truncated(row: 0, byteOffset: 6))
        XCTAssertEqual(JSONFixtures.indexError(#"{"a":"x"#) as? JSONTableError, .truncated(row: 0, byteOffset: 7))
        XCTAssertEqual(JSONFixtures.indexError("{\"a\":1}\n{\"b\":[") as? JSONTableError, .truncated(row: 1, byteOffset: 14))
        XCTAssertEqual(JSONFixtures.indexError(#"[{"a":1}"#, kind: .json) as? JSONTableError, .truncated(row: 1, byteOffset: 8))
        XCTAssertEqual(JSONFixtures.indexError(#"[{"a":1},"#, kind: .json) as? JSONTableError, .truncated(row: 1, byteOffset: 9))
        XCTAssertEqual(JSONFixtures.indexError("[", kind: .json) as? JSONTableError, .truncated(row: 0, byteOffset: 1))
    }

    func testMismatchedBracketThrows() {
        XCTAssertEqual(JSONFixtures.indexError(#"{"a":[1}"#) as? JSONTableError, .mismatchedBracket(row: 0, byteOffset: 7))
        XCTAssertEqual(
            JSONFixtures.indexError("{\"a\":1}\n{\"b\":{\"c\":2]}") as? JSONTableError,
            .mismatchedBracket(row: 1, byteOffset: 19)
        )
    }

    func testTrailingContentAfterArrayThrows() {
        XCTAssertEqual(
            JSONFixtures.indexError(#"[{"a":1}] x"#, kind: .json) as? JSONTableError,
            .trailingContent(row: 1, byteOffset: 10)
        )
    }

    func testArraySeparatorsAreChecked() {
        XCTAssertEqual(
            JSONFixtures.indexError(#"[{"a":1} {"a":2}]"#, kind: .json) as? JSONTableError,
            .unexpectedByte(row: 1, byteOffset: 9)
        )
        XCTAssertEqual(
            JSONFixtures.indexError(#"[{"a":1},]"#, kind: .json) as? JSONTableError,
            .unexpectedByte(row: 1, byteOffset: 9)
        )
    }

    func testUTF16ByteOrderMarkIsUnsupported() {
        for prefix: [UInt8] in [[0xFF, 0xFE, 0x5B, 0x00], [0xFE, 0xFF, 0x00, 0x5B]] {
            XCTAssertThrowsError(try JSONFixtures.index(prefix, kind: .json)) { error in
                XCTAssertEqual(error as? JSONTableError, .unsupportedEncoding)
            }
        }
    }

    func testEscapedKeysAreDecodedIntoOneColumn() throws {
        let index = try JSONFixtures.index("{\"a\\u0062\":1}\n{\"ab\":2}\n{\"\\\"q\\\"\":3}")
        XCTAssertEqual(index.keys, ["ab", "\"q\""])
    }

    func testOnlyTopLevelMembersBecomeKeys() throws {
        let index = try JSONFixtures.index(#"{"a":"x:{y}","b":{"c":1,"d":[{"e":2}]},"f":[{"g":3}]}"#)
        XCTAssertEqual(index.keys, ["a", "b", "f"])
    }

    func testEscapedQuotesAndBracketsInsideStringsAreIgnored() throws {
        let index = try JSONFixtures.index("{\"a\":\"he said \\\"}\\\" [\",\"b\":\"\\\\\"}\n{\"c\":1}")
        XCTAssertEqual(index.rowStarts, [0, 33])
        XCTAssertEqual(index.keys, ["a", "b", "c"])
    }

    func testDeepNestingBeyondSixtyFourLevels() throws {
        let depth = 150
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let index = try JSONFixtures.index("{\"deep\":\(nested),\"after\":1}\n{\"after\":2}")
        XCTAssertEqual(index.rowCount, 2)
        XCTAssertEqual(index.keys, ["deep", "after"])

        let broken = String(repeating: "[", count: depth) + "}" + String(repeating: "]", count: depth)
        XCTAssertEqual(
            JSONFixtures.indexError("{\"deep\":\(broken)}") as? JSONTableError,
            .mismatchedBracket(row: 0, byteOffset: 8 + depth)
        )
    }

    func testKeysAndRowsMatchTheRowParserAcrossBlockBoundaries() throws {
        var generator = SeededGenerator(state: 7)
        let fragments = ["a", "\\\\", "\\\"", "{", "}", "[", "]", ":", ",", " ", "\\u00e9", "\\n"]
        for trial in 0..<600 {
            let isArray = trial.isMultiple(of: 2)
            var text = isArray ? "[" : ""
            var starts: [Int] = []
            var expectedKeys: [String] = []
            for row in 0..<Int.random(in: 1...6, using: &generator) {
                if isArray, row > 0 {
                    text += ","
                }
                text += String(repeating: " ", count: Int.random(in: 0...70, using: &generator))
                starts.append(text.utf8.count)
                var members: [String] = []
                for member in 0..<Int.random(in: 0...4, using: &generator) {
                    let keyBody = (0..<Int.random(in: 0...12, using: &generator))
                        .map { _ in fragments.randomElement(using: &generator) ?? "a" }
                        .joined()
                    let key = "k\(row)\(member)\(keyBody)"
                    let valueBody = (0..<Int.random(in: 0...40, using: &generator))
                        .map { _ in fragments.randomElement(using: &generator) ?? "a" }
                        .joined()
                    let value = trial.isMultiple(of: 3) ? "[\"\(valueBody)\",{\"n\":\"\(valueBody)\"}]" : "\"\(valueBody)\""
                    members.append("\"\(key)\" : \(value)")
                }
                text += "{" + members.joined(separator: ",") + "}\n"
            }
            if isArray {
                text += "]"
            }
            let bytes = Array(text.utf8)
            let index = try JSONFixtures.index(bytes, kind: isArray ? .json : .jsonLines)
            XCTAssertEqual(index.rowStarts, starts, "trial \(trial)")
            try bytes.withUnsafeBufferPointer { buffer in
                for start in starts {
                    for member in try JSONRowParser.parseObject(in: buffer, at: start).members where !expectedKeys.contains(member.key) {
                        expectedKeys.append(member.key)
                    }
                }
            }
            XCTAssertEqual(index.keys, expectedKeys, "trial \(trial): \(text.debugDescription)")
        }
    }

    func testEscapeTrackerMatchesAByteLevelReference() {
        var generator = SeededGenerator(state: 42)
        let alphabet: [UInt8] = [JSONByte.backslash, JSONByte.backslash, JSONByte.quote, 0x61]
        for trial in 0..<3_000 {
            let blocks = Int.random(in: 1...4, using: &generator)
            let bytes = (0..<(blocks * JSONBlockMasks.width)).map { _ in alphabet.randomElement(using: &generator) ?? 0x61 }
            var expected = [Bool](repeating: false, count: bytes.count)
            var run = 0
            for (offset, byte) in bytes.enumerated() {
                expected[offset] = run % 2 == 1
                run = byte == JSONByte.backslash ? run + 1 : 0
            }
            var tracker = JSONEscapeTracker()
            var actual: [Bool] = []
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for block in 0..<blocks {
                    let masks = JSONBlockMasks(base + block * JSONBlockMasks.width)
                    let escaped = tracker.escapedBytes(backslashes: masks.backslash)
                    actual += (0..<64).map { escaped & (1 << UInt64($0)) != 0 }
                }
            }
            XCTAssertEqual(actual, expected, "trial \(trial)")
        }
    }

    private static let manyRowsCount = 20_000

    private static let manyRows: [UInt8] = {
        let row = Array("{\"a\":\"\(String(repeating: "x", count: 1_000))\"}\n".utf8)
        let rowCount = manyRowsCount
        var bytes = [UInt8](repeating: 0, count: row.count * rowCount)
        bytes.withUnsafeMutableBytes { target in
            row.withUnsafeBytes { pattern in
                for offset in stride(from: 0, to: target.count, by: pattern.count) {
                    UnsafeMutableRawBufferPointer(rebasing: target[offset..<(offset + pattern.count)]).copyMemory(from: pattern)
                }
            }
        }
        return bytes
    }()

    func testCancellationStopsIndexing() {
        XCTAssertThrowsError(
            try Self.manyRows.withUnsafeBufferPointer {
                try JSONTableIndexer.index($0, fileKind: .jsonLines, isCancelled: { true })
            }
        ) { error in
            XCTAssertTrue(error is TabularCancellation)
        }
    }

    func testCancellationStopsIndexingInsideOneLongRow() {
        let bytes = Array("{\"a\":\"".utf8) + [UInt8](repeating: 0x78, count: 20_000_000) + Array("\"}".utf8)
        XCTAssertThrowsError(
            try bytes.withUnsafeBufferPointer { try JSONTableIndexer.index($0, fileKind: .jsonLines, isCancelled: { true }) }
        ) { error in
            XCTAssertTrue(error is TabularCancellation)
        }
    }

    func testProgressIsReportedAndEndsAtOne() throws {
        final class Recorder: @unchecked Sendable {
            var values: [Double] = []
        }
        let recorder = Recorder()
        let index = try Self.manyRows.withUnsafeBufferPointer {
            try JSONTableIndexer.index($0, fileKind: .jsonLines, progress: { recorder.values.append($0) })
        }
        XCTAssertEqual(index.rowCount, Self.manyRowsCount)
        XCTAssertGreaterThan(recorder.values.count, 1)
        XCTAssertEqual(recorder.values.last, 1)
        XCTAssertEqual(recorder.values, recorder.values.sorted())
    }

    func testFileKindFollowsTheExtension() {
        XCTAssertEqual(JSONTableFileKind.forFileExtension("JSONL"), .jsonLines)
        XCTAssertEqual(JSONTableFileKind.forFileExtension("ndjson"), .jsonLines)
        XCTAssertEqual(JSONTableFileKind.forFileExtension("json"), .json)
    }
}
