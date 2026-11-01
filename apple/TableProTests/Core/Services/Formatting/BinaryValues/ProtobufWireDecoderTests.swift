//
//  ProtobufWireDecoderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

// Each expectation is what `protoc --decode_raw` (libprotoc 36.2) printed for the same bytes, except that UTF-8 text
// keeps its characters.
struct ProtobufWireDecoderTests {
    // protoc --encode of a message setting every wire type, a nested and a repeated message, and field 1000.
    private static let order = "089601120774657374696e671a0908011205636166c3a925070000002909000000000000003206038e029ea7053a"
        + "030001ff400348ffffffffffffffffff01516e861bf0f92109405d0000c03f6202080262050803120178c03eb5b8f0fe2d"

    private static func text(_ hex: String, multiLine: Bool = true) throws -> String {
        ProtobufTextWriter.text(try ProtobufWireDecoder.decode(BinaryFixture.data(hex)).fields, multiLine: multiLine)
    }

    @Test("Every wire type, nested and repeated messages, and a field number past 127")
    func order() throws {
        let expected = """
        1: 150
        2: "testing"
        3 {
          1: 1
          2: "café"
        }
        4: 0x00000007
        5: 0x0000000000000009
        6: "\\003\\216\\002\\236\\247\\005"
        7: "\\000\\001\\377"
        8: 3
        9: 18446744073709551615
        10: 0x400921f9f01b866e
        11: 0x3fc00000
        12 {
          1: 2
        }
        12 {
          1: 3
          2: "x"
        }
        1000: 12345678901

        """
        #expect(try Self.text(Self.order) == expected)
    }

    @Test("A proto2 group")
    func group() throws {
        let expected = """
        1: 1
        2 {
          3: "http://x"
          4: 2
        }
        5: "end"

        """
        // protoc --encode of a proto2 message with a group between two fields.
        #expect(try Self.text("0801131a08687474703a2f2f782002142a03656e64") == expected)
        let message = try ProtobufWireDecoder.decode(BinaryFixture.data("0801131a08687474703a2f2f782002142a03656e64"))
        #expect(message.fields[1].value == .group([
            ProtobufField(number: 3, value: .string("http://x")),
            ProtobufField(number: 4, value: .varint(2)),
        ]))
    }

    @Test("An empty value is an empty message")
    func empty() throws {
        #expect(try ProtobufWireDecoder.decode(Data()).fields.isEmpty)
        #expect(try Self.text("0a00") == "1: \"\"\n")
    }

    @Test("A Schema Registry frame is read off the front")
    func framing() throws {
        let single = try ProtobufWireDecoder.decode(BinaryFixture.data("000000002a00089601"))
        #expect(single.framing == ProtobufFraming(schemaID: 42, messageIndexes: [0]))
        #expect(single.fields == [ProtobufField(number: 1, value: .varint(150))])
        let nested = try ProtobufWireDecoder.decode(BinaryFixture.data("000000002a040204089601"))
        #expect(nested.framing == ProtobufFraming(schemaID: 42, messageIndexes: [1, 2]))
    }

    @Test(
        "Broken values are refused where they break",
        arguments: [
            ("08", BinaryValueDecodeError(kind: .unexpectedEnd, offset: 1)),
            ("0a05ab", BinaryValueDecodeError(kind: .unexpectedEnd, offset: 3)),
            ("0c", BinaryValueDecodeError(kind: .unmatchedGroupEnd, offset: 0)),
            ("0f", BinaryValueDecodeError(kind: .invalidField, offset: 0)),
            ("0b0801", BinaryValueDecodeError(kind: .unexpectedEnd, offset: 3)),
        ]
    )
    func broken(hex: String, error: BinaryValueDecodeError) {
        #expect(throws: error) {
            try ProtobufWireDecoder.decode(BinaryFixture.data(hex))
        }
    }

    @Test("A budgeted decode stops after the fields it may show")
    func budget() throws {
        let message = try ProtobufWireDecoder.decode(BinaryFixture.data(Self.order), maxValues: 2)
        #expect(ProtobufTextWriter.text(message.fields, multiLine: false) == #"1: 150 2: "testing" …"#)
    }

    @Test("A length-delimited value spends the caller's budget and leaves the rest of it")
    func lengthDelimitedBudget() {
        // Hand-written: `1: 1`, `1: 2`, `1: 3`.
        let window = BinaryValueReader(BinaryFixture.data("080108020803"))
        var budget = 2
        let value = ProtobufWireDecoder.lengthDelimited(window, depth: 0, budget: &budget)
        #expect(value == .message([
            ProtobufField(number: 1, value: .varint(1)),
            ProtobufField(number: 1, value: .varint(2)),
            ProtobufField(number: 0, value: .truncated),
        ]))
        #expect(budget == 0)
        var roomy = 10
        _ = ProtobufWireDecoder.lengthDelimited(window, depth: 0, budget: &roomy)
        #expect(roomy == 7)
    }

    @Test("The tree keys fields by number and badges their wire type")
    func tree() throws {
        let message = try ProtobufWireDecoder.decode(BinaryFixture.data(Self.order))
        let tree = ProtobufTreeBuilder.build(from: message.fields, formats: BinaryFixture.english)
        #expect(tree.displayValue == "{14 fields}")
        let first = Array(tree.children.prefix(5))
        #expect(first.map { $0.key } == ["1", "2", "3", "4", "5"])
        #expect(first.map { $0.badgeLabel } == ["varint", "len", "len", "i32", "i64"])
        #expect(first[2].children.map { $0.keyPath } == ["3.1", "3.2"])
        #expect(first[2].copyableValue == #"1: 1 2: "café""#)
        #expect(tree.children.last?.key == "1000")
    }
}
