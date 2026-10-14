import Foundation
@testable import TableProTabularIO
import Testing

struct JSONSourceTests {
    @Test func testSourceDescribesItsColumnsAndRows() async throws {
        let source = try await JSONFixtures.source("{\"b\":1,\"a\":2}\n{\"c\":3}\n")
        #expect(source.shape == .lines)
        #expect(source.rowCount == 2)
        #expect(source.columnCount == 3)
        #expect(source.intrinsicColumnNames == ["b", "a", "c"])
        #expect(source.absentCell == .missing)
    }

    @Test func testNumberLexemesAreKeptExactly() async throws {
        let source = try await JSONFixtures.source(
            #"{"a":1.0,"b":-0,"c":1e5,"d":12345678901234567890,"e":0.1,"f":1E+2,"g":-1.5e-3}"#
        )
        #expect(JSONFixtures.texts(source, row: 0) == ["1.0", "-0", "1e5", "12345678901234567890", "0.1", "1E+2", "-1.5e-3"])
        #expect(Set(JSONFixtures.kinds(source, row: 0)) == [.number])
    }

    @Test func testStringEscapesAndSurrogatePairsAreDecoded() async throws {
        let source = try await JSONFixtures.source(
            #"{"a":"é","b":"😀","c":"\n\t\"\\\/\b\f\r","d":"\ud800x","e":"plain","f":"cafÉ"}"#
        )
        #expect(JSONFixtures.texts(source, row: 0) == ["é", "😀", "\n\t\"\\/\u{08}\u{0C}\r", "\u{FFFD}x", "plain", "cafÉ"])
        #expect(Set(JSONFixtures.kinds(source, row: 0)) == [.text])
    }

    @Test func testRawUnicodeTextIsReadAsIs() async throws {
        let source = try await JSONFixtures.source("{\"tên\":\"Hà Nội 🇻🇳\"}")
        #expect(source.intrinsicColumnNames == ["tên"])
        #expect(source.cell(row: 0, column: 0) == TabularCell(kind: .text, text: "Hà Nội 🇻🇳"))
    }

    @Test func testEscapedAndPlainSpellingsOfAKeyFillOneColumn() async throws {
        let source = try await JSONFixtures.source("{\"a\\u0062\":1,\"z\":0}\n{\"z\":0,\"ab\":2}\n{\"\\u0061b\":3}\n")
        #expect(source.intrinsicColumnNames == ["ab", "z"])
        #expect((0..<3).map { source.cell(row: $0, column: 0).text } == ["1", "2", "3"])
    }

    @Test func testDuplicateKeysShowTheLastOccurrence() async throws {
        let source = try await JSONFixtures.source(#"{"a":1,"b":2,"a":"three"}"#)
        #expect(source.intrinsicColumnNames == ["a", "b"])
        #expect(source.cells(row: 0) == [TabularCell(kind: .text, text: "three"), TabularCell(kind: .number, text: "2")])
    }

    @Test func testNestedContainersAreShownCompact() async throws {
        let source = try await JSONFixtures.source(
            "{\"o\": { \"a\" : [1, 2],\n \"s\": \"x y\" }, \"e\": [ ], \"p\": {}, \"q\": [{\"k\":\"\\\" \"}]}"
        )
        #expect(source.cells(row: 0) == [
            TabularCell(kind: .object, text: #"{"a":[1,2],"s":"x y"}"#),
            TabularCell(kind: .array, text: "[]"),
            TabularCell(kind: .object, text: "{}"),
            TabularCell(kind: .array, text: #"[{"k":"\" "}]"#)
        ])
    }

    @Test func testMissingNullAndEmptyStringAreDistinct() async throws {
        let source = try await JSONFixtures.source("{\"a\":null,\"b\":\"\"}\n{\"b\":\"x\"}\n")
        #expect(source.cells(row: 0) == [TabularCell(kind: .null, text: "null"), TabularCell(kind: .text, text: "")])
        #expect(source.cells(row: 1) == [TabularCell.missing, TabularCell(kind: .text, text: "x")])
    }

    @Test func testBooleansKeepTheirLiteralText() async throws {
        let source = try await JSONFixtures.source(#"{"t":true,"f":false}"#)
        #expect(source.cells(row: 0) == [TabularCell(kind: .boolean, text: "true"), TabularCell(kind: .boolean, text: "false")])
    }

    @Test func testCellOutsideTheTableIsMissing() async throws {
        let source = try await JSONFixtures.source(#"{"a":1}"#)
        #expect(source.cell(row: 1, column: 0) == .missing)
        #expect(source.cell(row: 0, column: 1) == .missing)
        #expect(source.cell(row: -1, column: 0) == .missing)
        #expect(source.cells(row: 3).isEmpty)
    }

    @Test func testScanFillsRequestedColumnsInTheOrderAsked() async throws {
        let source = try await JSONFixtures.source("{\"a\":\"a0\",\"b\":\"b0\",\"c\":\"c0\"}\n{\"c\":\"c1\",\"a\":\"a1\"}\n")
        var seen: [(Int, [String], [TabularCellKind])] = []
        source.scan(columns: [2, 0, 1], rows: [1, 0]) { row, cells in
            seen.append((row, (0..<cells.count).map { cells.string(at: $0) }, cells.kinds))
            return true
        }
        #expect(seen.map(\.0) == [1, 0])
        #expect(seen.map(\.1) == [["c1", "a1", ""], ["c0", "a0", "b0"]])
        #expect(seen[0].2 == [.text, .text, .missing])
    }

    @Test func testScanFillsEverySlotThatAsksForTheSameColumn() async throws {
        let source = try await JSONFixtures.source("{\"a\":\"x\",\"b\":\"y\"}\n")
        var seen: [String] = []
        source.scan(columns: [1, 0, 1, 7], rows: [0]) { _, cells in
            seen = (0..<cells.count).map { cells.string(at: $0) }
            return true
        }
        #expect(seen == ["y", "x", "y", ""])
    }

    @Test func testBulkRangeListAndGenericScansAgreeWithSingleCellReads() async throws {
        let text = (0..<1_000).map { "{\"n\":\($0),\"s\":\"v\\\"\($0)\",\"o\":{ \"k\" : \($0) }}\n" }.joined()
        let source = try await JSONFixtures.source(text)
        let expected = (0..<1_000).reversed().map { row in (0..<3).map { source.cell(row: row, column: $0) } }
        func collect<Rows: Collection>(_ rows: Rows) -> [[TabularCell]] where Rows.Element == Int {
            var seen: [[TabularCell]] = []
            source.scan(columns: [0, 1, 2], rows: rows) { _, cells in
                seen.append((0..<cells.count).map { TabularCell(kind: cells.kinds[$0], text: cells.string(at: $0)) })
                return true
            }
            return seen
        }
        #expect(Array(collect(0..<1_000).reversed()) == expected)
        #expect(collect(Array((0..<1_000).reversed())) == expected)
        #expect(collect((0..<1_000).reversed()) == expected)
        #expect(expected.last == [TabularCell(kind: .number, text: "0"), .text("v\"0"), TabularCell(kind: .object, text: #"{"k":0}"#)])
    }

    @Test func testScanStopsWhenTheBodyReturnsFalse() async throws {
        let source = try await JSONFixtures.source("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
        var rows: [Int] = []
        source.scan(columns: [0], rows: 0..<3) { row, _ in
            rows.append(row)
            return row < 1
        }
        #expect(rows == [0, 1])
    }

    @Test func testObjectLayoutReportsMemberSpans() async throws {
        let source = try await JSONFixtures.source(#"{"a": 1, "b":"x"}"#)
        let layout = try source.objectLayout(ofRow: 0)
        #expect(layout.range == (0..<17))
        #expect(layout.members == [
            JSONMember(key: "a", keyRange: 1..<4, valueRange: 6..<7, kind: .number),
            JSONMember(key: "b", keyRange: 9..<12, valueRange: 13..<16, kind: .text)
        ])
        #expect(layout.lastMember(forKey: "b")?.valueRange == (13..<16))
        #expect(try source.objectRange(ofRow: 0) == (0..<17))
    }

    @Test func testRowParserDisplaysAMember() throws {
        let bytes = Array(#"{"kA":"é", "o":[ 1 ]}"#.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            let layout = try JSONRowParser.parseObject(in: buffer, at: 0)
            #expect(layout.members.map(\.key) == ["kA", "o"])
            #expect(JSONRowParser.cell(for: layout.members[0], in: buffer) == TabularCell(kind: .text, text: "é"))
            #expect(JSONRowParser.cell(for: layout.members[1], in: buffer) == TabularCell(kind: .array, text: "[1]"))
        }
    }

    @Test func testBuilderRejectsInvalidRowContent() async {
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
            #expect(error as? JSONTableError == expected, "\(text)")
        }
    }

    @Test func testBuilderReportsTheEarliestInvalidRow() async {
        var lines = [String](repeating: #"{"a":1}"#, count: 20_000)
        lines[15_000] = #"{"a":tru}"#
        lines[9_000] = #"{"a":01}"#
        let error = await JSONFixtures.buildError(lines.joined(separator: "\n"))
        #expect(error as? JSONTableError == .invalidNumber(row: 9_000, byteOffset: 9_000 * 8 + 5))
    }

    @Test func testBuilderStopsWhenCancelled() async {
        do {
            _ = try await JSONSourceBuilder.build(bytes: Data("{\"a\":1}\n".utf8), fileKind: .jsonLines, isCancelled: { true })
            Issue.record("expected cancellation")
        } catch {
            #expect(error is TabularCancellation)
        }
    }

    @Test func testBuilderReportsProgressUpToOne() async throws {
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
        #expect(abs((recorder.values.last ?? 0) - (1)) <= 0.0001)
    }
}
