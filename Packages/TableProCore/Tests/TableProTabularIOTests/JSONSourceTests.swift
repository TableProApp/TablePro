import Foundation
@testable import TableProTabularIO
import XCTest

final class JSONSourceTests: XCTestCase {
    func testSourceDescribesItsColumnsAndRows() async throws {
        let source = try await JSONFixtures.source("{\"b\":1,\"a\":2}\n{\"c\":3}\n")
        XCTAssertEqual(source.shape, .lines)
        XCTAssertEqual(source.rowCount, 2)
        XCTAssertEqual(source.columnCount, 3)
        XCTAssertEqual(source.intrinsicColumnNames, ["b", "a", "c"])
        XCTAssertEqual(source.absentCell, .missing)
    }

    func testNumberLexemesAreKeptExactly() async throws {
        let source = try await JSONFixtures.source(
            #"{"a":1.0,"b":-0,"c":1e5,"d":12345678901234567890,"e":0.1,"f":1E+2,"g":-1.5e-3}"#
        )
        XCTAssertEqual(JSONFixtures.texts(source, row: 0), ["1.0", "-0", "1e5", "12345678901234567890", "0.1", "1E+2", "-1.5e-3"])
        XCTAssertEqual(Set(JSONFixtures.kinds(source, row: 0)), [.number])
    }

    func testStringEscapesAndSurrogatePairsAreDecoded() async throws {
        let source = try await JSONFixtures.source(
            #"{"a":"é","b":"😀","c":"\n\t\"\\\/\b\f\r","d":"\ud800x","e":"plain","f":"cafÉ"}"#
        )
        XCTAssertEqual(
            JSONFixtures.texts(source, row: 0),
            ["é", "😀", "\n\t\"\\/\u{08}\u{0C}\r", "\u{FFFD}x", "plain", "cafÉ"]
        )
        XCTAssertEqual(Set(JSONFixtures.kinds(source, row: 0)), [.text])
    }

    func testRawUnicodeTextIsReadAsIs() async throws {
        let source = try await JSONFixtures.source("{\"tên\":\"Hà Nội 🇻🇳\"}")
        XCTAssertEqual(source.intrinsicColumnNames, ["tên"])
        XCTAssertEqual(source.cell(row: 0, column: 0), TabularCell(kind: .text, text: "Hà Nội 🇻🇳"))
    }

    func testDuplicateKeysShowTheLastOccurrence() async throws {
        let source = try await JSONFixtures.source(#"{"a":1,"b":2,"a":"three"}"#)
        XCTAssertEqual(source.intrinsicColumnNames, ["a", "b"])
        XCTAssertEqual(source.cells(row: 0), [TabularCell(kind: .text, text: "three"), TabularCell(kind: .number, text: "2")])
    }

    func testNestedContainersAreShownCompact() async throws {
        let source = try await JSONFixtures.source(
            "{\"o\": { \"a\" : [1, 2],\n \"s\": \"x y\" }, \"e\": [ ], \"p\": {}, \"q\": [{\"k\":\"\\\" \"}]}"
        )
        XCTAssertEqual(
            source.cells(row: 0),
            [
                TabularCell(kind: .object, text: #"{"a":[1,2],"s":"x y"}"#),
                TabularCell(kind: .array, text: "[]"),
                TabularCell(kind: .object, text: "{}"),
                TabularCell(kind: .array, text: #"[{"k":"\" "}]"#)
            ]
        )
    }

    func testMissingNullAndEmptyStringAreDistinct() async throws {
        let source = try await JSONFixtures.source("{\"a\":null,\"b\":\"\"}\n{\"b\":\"x\"}\n")
        XCTAssertEqual(source.cells(row: 0), [TabularCell(kind: .null, text: "null"), TabularCell(kind: .text, text: "")])
        XCTAssertEqual(source.cells(row: 1), [TabularCell.missing, TabularCell(kind: .text, text: "x")])
    }

    func testBooleansKeepTheirLiteralText() async throws {
        let source = try await JSONFixtures.source(#"{"t":true,"f":false}"#)
        XCTAssertEqual(source.cells(row: 0), [TabularCell(kind: .boolean, text: "true"), TabularCell(kind: .boolean, text: "false")])
    }

    func testCellOutsideTheTableIsMissing() async throws {
        let source = try await JSONFixtures.source(#"{"a":1}"#)
        XCTAssertEqual(source.cell(row: 1, column: 0), .missing)
        XCTAssertEqual(source.cell(row: 0, column: 1), .missing)
        XCTAssertEqual(source.cell(row: -1, column: 0), .missing)
        XCTAssertEqual(source.cells(row: 3), [])
    }

    func testScanFillsRequestedColumnsInTheOrderAsked() async throws {
        let source = try await JSONFixtures.source("{\"a\":\"a0\",\"b\":\"b0\",\"c\":\"c0\"}\n{\"c\":\"c1\",\"a\":\"a1\"}\n")
        var seen: [(Int, [String], [TabularCellKind])] = []
        source.scan(columns: [2, 0, 1], rows: [1, 0]) { row, cells in
            seen.append((row, (0..<cells.count).map { cells.string(at: $0) }, cells.kinds))
            return true
        }
        XCTAssertEqual(seen.map(\.0), [1, 0])
        XCTAssertEqual(seen.map(\.1), [["c1", "a1", ""], ["c0", "a0", "b0"]])
        XCTAssertEqual(seen[0].2, [.text, .text, .missing])
    }

    func testScanFillsEverySlotThatAsksForTheSameColumn() async throws {
        let source = try await JSONFixtures.source("{\"a\":\"x\",\"b\":\"y\"}\n")
        var seen: [String] = []
        source.scan(columns: [1, 0, 1, 7], rows: [0]) { _, cells in
            seen = (0..<cells.count).map { cells.string(at: $0) }
            return true
        }
        XCTAssertEqual(seen, ["y", "x", "y", ""])
    }

    func testScanStopsWhenTheBodyReturnsFalse() async throws {
        let source = try await JSONFixtures.source("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
        var rows: [Int] = []
        source.scan(columns: [0], rows: 0..<3) { row, _ in
            rows.append(row)
            return row < 1
        }
        XCTAssertEqual(rows, [0, 1])
    }

    func testObjectLayoutReportsMemberSpans() async throws {
        let source = try await JSONFixtures.source(#"{"a": 1, "b":"x"}"#)
        let layout = try source.objectLayout(ofRow: 0)
        XCTAssertEqual(layout.range, 0..<17)
        XCTAssertEqual(
            layout.members,
            [
                JSONMember(key: "a", keyRange: 1..<4, valueRange: 6..<7, kind: .number),
                JSONMember(key: "b", keyRange: 9..<12, valueRange: 13..<16, kind: .text)
            ]
        )
        XCTAssertEqual(layout.lastMember(forKey: "b")?.valueRange, 13..<16)
        XCTAssertEqual(try source.objectRange(ofRow: 0), 0..<17)
    }

    func testRowParserDisplaysAMember() throws {
        let bytes = Array(#"{"kA":"é", "o":[ 1 ]}"#.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            let layout = try JSONRowParser.parseObject(in: buffer, at: 0)
            XCTAssertEqual(layout.members.map(\.key), ["kA", "o"])
            XCTAssertEqual(JSONRowParser.cell(for: layout.members[0], in: buffer), TabularCell(kind: .text, text: "é"))
            XCTAssertEqual(JSONRowParser.cell(for: layout.members[1], in: buffer), TabularCell(kind: .array, text: "[1]"))
        }
    }

    func testBuilderRejectsInvalidRowContent() async {
        let cases: [(String, JSONTableError)] = [
            (#"{"a":01}"#, .invalidNumber(row: 0, byteOffset: 5)),
            (#"{"a":1.}"#, .invalidNumber(row: 0, byteOffset: 5)),
            (#"{"a":-}"#, .invalidNumber(row: 0, byteOffset: 5)),
            (#"{"a":1e}"#, .invalidNumber(row: 0, byteOffset: 5)),
            (#"{"a":+1}"#, .unexpectedByte(row: 0, byteOffset: 5)),
            (#"{"a":tru}"#, .invalidLiteral(row: 0, byteOffset: 5)),
            (#"{"a":nulls}"#, .invalidLiteral(row: 0, byteOffset: 5)),
            (#"{"a":"\x"}"#, .invalidEscape(row: 0, byteOffset: 6)),
            (#"{"a":"\u12G4"}"#, .invalidEscape(row: 0, byteOffset: 6)),
            ("{\"a\":\"x\ty\"}", .invalidString(row: 0, byteOffset: 7)),
            (#"{"a" 1}"#, .unexpectedByte(row: 0, byteOffset: 5)),
            (#"{"a":1,}"#, .unexpectedByte(row: 0, byteOffset: 7)),
            (#"{"a":1 "b":2}"#, .unexpectedByte(row: 0, byteOffset: 7)),
            (#"{"a":[1,]}"#, .unexpectedByte(row: 0, byteOffset: 8)),
            (#"{"a":{"b"}}"#, .unexpectedByte(row: 0, byteOffset: 9)),
            (#"{1:2}"#, .unexpectedByte(row: 0, byteOffset: 1)),
            ("{\"a\":1}\n{\"a\":01}", .invalidNumber(row: 1, byteOffset: 13))
        ]
        for (text, expected) in cases {
            let error = await JSONFixtures.buildError(text)
            XCTAssertEqual(error as? JSONTableError, expected, text)
        }
    }

    func testBuilderReportsTheEarliestInvalidRow() async {
        var lines = [String](repeating: #"{"a":1}"#, count: 20_000)
        lines[15_000] = #"{"a":tru}"#
        lines[9_000] = #"{"a":01}"#
        let error = await JSONFixtures.buildError(lines.joined(separator: "\n"))
        XCTAssertEqual(error as? JSONTableError, .invalidNumber(row: 9_000, byteOffset: 9_000 * 8 + 5))
    }

    func testBuilderStopsWhenCancelled() async {
        do {
            _ = try await JSONSourceBuilder.build(bytes: Data("{\"a\":1}\n".utf8), fileKind: .jsonLines, isCancelled: { true })
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is TabularCancellation)
        }
    }

    func testBuilderReportsProgressUpToOne() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Double] = []

            func append(_ value: Double) {
                lock.lock()
                storage.append(value)
                lock.unlock()
            }

            var values: [Double] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }
        let recorder = Recorder()
        _ = try await JSONSourceBuilder.build(
            bytes: Data(String(repeating: "{\"a\":1}\n", count: 10_000).utf8),
            fileKind: .jsonLines,
            progress: { recorder.append($0) }
        )
        XCTAssertEqual(recorder.values.last ?? 0, 1, accuracy: 0.0001)
    }
}
