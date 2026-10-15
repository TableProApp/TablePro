import Foundation
@testable import TableProBigtableCore
import Testing

struct BigtableChunkAssemblerTests {
    @Test("Family and qualifier carry over, split values join, and only committed rows count")
    func assembly() throws {
        let response = json("""
        [{"chunks": [
          {"rowKey": "\(b64("r1"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "10", "value": "\(b64("he"))", "valueSize": 5},
          {"value": "\(b64("llo"))"},
          {"qualifier": "\(b64("b"))", "timestampMicros": "10", "value": "\(b64("x"))", "commitRow": true}
        ]},
        {"chunks": [
          {"rowKey": "\(b64("r2"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "1", "value": "\(b64("old"))"},
          {"resetRow": true},
          {"rowKey": "\(b64("r2"))", "familyName": {"value": "cf"}, "qualifier": "\(b64("a"))", "timestampMicros": "2", "value": "\(b64("new"))", "commitRow": true}
        ]}]
        """)
        let rows = try BigtableChunkAssembler.rows(fromResponse: response, operation: "read t")
        let a = BigtableColumn(family: "cf", qualifier: Data("a".utf8))
        #expect(rows.map(\.key) == [Data("r1".utf8), Data("r2".utf8)])
        #expect(rows[0].cells[a]?.value == Data("hello".utf8))
        #expect(rows[0].cells[BigtableColumn(family: "cf", qualifier: Data("b".utf8))]?.value == Data("x".utf8))
        #expect(rows[1].cells[a] == BigtableCell(value: Data("new".utf8), timestampMicros: 2))
    }

    @Test("A response that stops inside a row is refused")
    func truncated() {
        let response = json("""
        [{"chunks": [{"rowKey": "\(b64("r1"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "1", "value": "\(b64("v"))"}]}]
        """)
        #expect(throws: BigtableError.self) { try BigtableChunkAssembler.rows(fromResponse: response, operation: "read t") }
    }

    @Test("An error that ends a stream after its first rows fails the read instead of shortening it")
    func streamError() {
        let response = json("""
        [{"chunks": [{"rowKey": "\(b64("r1"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "1", "value": "", "commitRow": true}]},
         {"error": {"code": 503, "message": "The service is unavailable.", "status": "UNAVAILABLE"}}]
        """)
        #expect(throws: BigtableError.api(status: 503, message: "The service is unavailable.")) {
            try BigtableChunkAssembler.rows(fromResponse: response, operation: "read t")
        }
    }
}

struct BigtableRowSetTests {
    @Test("Rows lay out with _key first, columns in order, and missing cells absent")
    func layout() {
        let a = BigtableColumn(family: "cf", qualifier: Data("a".utf8))
        let z = BigtableColumn(family: "meta", qualifier: Data([0xFF, 0x00]))
        let set = BigtableRowSet(rows: [
            BigtableRow(key: Data("k1".utf8), cells: [a: BigtableCell(value: Data("v".utf8), timestampMicros: 1)]),
            BigtableRow(key: Data([0x00, 0x01]), cells: [z: BigtableCell(value: Data([0xC3]), timestampMicros: 1)])
        ])
        #expect(set.columns == ["_key", "cf:a", "meta:b64:/wA="])
        #expect(set.rows[0] == [.text("k1"), .text("v"), .absent])
        #expect(set.rows[1] == [.text("b64:AAE="), .absent, .bytes(Data([0xC3]))])
        #expect(set.absentCells == [0: [2], 1: [1]])
        #expect(set.locators == [b64("k1"), Data([0x00, 0x01]).base64EncodedString()])
    }

    @Test("Text that starts with b64: reaches the grid as bytes, so writing it back keeps it as text")
    func taggedTextRoundTrips() throws {
        let stored = Data("b64:AAE=".utf8)
        let a = BigtableColumn(family: "cf", qualifier: Data("a".utf8))
        let set = BigtableRowSet(rows: [BigtableRow(key: Data("k".utf8), cells: [a: BigtableCell(value: stored, timestampMicros: 1)])])
        #expect(set.rows[0][1] == .bytes(stored))

        let write = try #require(try BigtableRowWrites.update(table: "t", key: Data("k".utf8), changes: [("cf:a", set.rows[0][1])]))
        #expect(try write.mutations() == [.setCell(a, stored)])
    }

    @Test("An export page lines up under the first page's columns and keeps the rest in __extra__")
    func exportAlignment() {
        let a = BigtableColumn(family: "cf", qualifier: Data("a".utf8))
        let b = BigtableColumn(family: "cf", qualifier: Data("b".utf8))
        let page = BigtableRowSet(rows: [
            BigtableRow(key: Data("k1".utf8), cells: [a: BigtableCell(value: Data("1".utf8), timestampMicros: 1)]),
            BigtableRow(key: Data("k2".utf8), cells: [b: BigtableCell(value: Data("x/y".utf8), timestampMicros: 1)])
        ])
        let header = ["_key", "cf:a", BigtableRowSet.extraColumn]
        #expect(page.rows(alignedTo: header) == [
            [.text("k1"), .text("1"), .absent],
            [.text("k2"), .absent, .text(#"{"cf:b":"x/y"}"#)]
        ])
    }
}

struct BigtableBytesTests {
    @Test("Printable text shows as itself, anything else as b64 that reads back")
    func displayRoundTrip() throws {
        for data in [Data("user#42".utf8), Data([0, 1, 255]), Data("b64:looks-tagged".utf8), Data("line\u{07}bell".utf8)] {
            #expect(try BigtableBytes.parse(BigtableBytes.display(data)) == data)
        }
        #expect(BigtableBytes.display(Data("user#42".utf8)) == "user#42")
        #expect(throws: BigtableError.self) { try BigtableBytes.parse("b64:***") }
    }

    @Test("Prefix end increments the last byte that can grow")
    func prefixEnd() {
        #expect(BigtableBytes.prefixEnd(Data("ab".utf8)) == Data("ac".utf8))
        #expect(BigtableBytes.prefixEnd(Data([0x61, 0xFF])) == Data([0x62]))
        #expect(BigtableBytes.prefixEnd(Data([0xFF, 0xFF])) == nil)
    }

    @Test("Regex literals escape operators and non-printable bytes")
    func regexLiteral() {
        #expect(BigtableBytes.regexText(Data("a.b*(c)".utf8)) == #"a\.b\*\(c\)"#)
        #expect(BigtableBytes.regexText(Data([0x00, 0x41])) == #"\x00A"#)
    }

    @Test("A column name splits at its first colon")
    func columnNames() throws {
        let column = try BigtableColumn(name: "cf:a:b")
        #expect(column.family == "cf" && column.qualifier == Data("a:b".utf8))
        #expect(try BigtableColumn(name: "cf:b64:/wA=").qualifier == Data([0xFF, 0x00]))
        #expect(throws: BigtableError.self) { try BigtableColumn(name: "nocolon") }
        #expect(throws: BigtableError.self) { try BigtableColumn(name: ":q") }
    }
}
