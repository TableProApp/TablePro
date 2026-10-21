//
//  MessagePackDecoderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Fixtures written by msgpack-python 1.1.0, `msgpack.packb(value, use_bin_type=True)`.
struct MessagePackDecoderTests {
    private static func json(_ hex: String) throws -> String {
        MessagePackTextWriter.json(try MessagePackDecoder.decode(BinaryFixture.data(hex)), pretty: false)
    }

    @Test("A map of a bool and an int")
    func map() throws {
        #expect(try Self.json("82a7636f6d70616374c3a6736368656d6100") == #"{"compact":true,"schema":0}"#)
    }

    @Test("Every scalar family, with uint64 and int64 at their limits")
    func mixed() throws {
        let hex = "8aa46e616d65a3416e6ea36167651ea47461677392a161a162a573636f7265cb3ff8000000000000a6616374697665c2"
            + "a46e6f6e65c0a36e6567d0dfa3626967cfffffffffffffffffa36d696ed38000000000000000a3663332cb0000000000000000"
        let expected = #"{"name":"Ann","age":30,"tags":["a","b"],"score":1.5,"active":false,"none":null,"neg":-33,"#
            + #""big":18446744073709551615,"min":-9223372036854775808,"f32":0.0}"#
        #expect(try Self.json(hex) == expected)
    }

    @Test("bin is written as hex")
    func binary() throws {
        #expect(try Self.json("81a77061796c6f6164c4040001feff") == #"{"payload":"0x0001FEFF"}"#)
    }

    @Test("An extension keeps its type and bytes")
    func extensionType() throws {
        #expect(try MessagePackDecoder.decode(BinaryFixture.data("92d505a1b201"))
            == .array([.ext(type: 5, data: Data([0xA1, 0xB2])), .uint(1)]))
        #expect(try Self.json("92d505a1b201") == #"["ext(5) 0xA1B2",1]"#)
    }

    @Test(
        "The three timestamp layouts read as RFC 3339 UTC",
        arguments: [
            ("d6ff6553f100", "2023-11-14T22:13:20Z"),
            ("d7ff1d6f34546553f100", "2023-11-14T22:13:20.123456789Z"),
            ("c70cff000001f4ffffffffffffffff", "1969-12-31T23:59:59.0000005Z"),
        ]
    )
    func timestamps(hex: String, expected: String) throws {
        #expect(try Self.json(hex) == "\"\(expected)\"")
    }

    @Test("Integer keys keep their value as the key")
    func integerKeys() throws {
        #expect(try Self.json("8201a36f6e650291c3") == #"{"1":"one","2":[true]}"#)
    }

    @Test("UTF-8 text, nesting and the 16-bit headers")
    func structure() throws {
        #expect(try Self.json("a9636166c3a920e29895") == "\"café ☕\"")
        #expect(try Self.json("9291919080") == "[[[[]]],{}]")
        let counted = "[" + (0..<20).map { String($0) }.joined(separator: ",") + "]"
        #expect(try Self.json("dc0014000102030405060708090a0b0c0d0e0f10111213") == counted)
    }

    @Test("float32 and float64")
    func floats() throws {
        #expect(try MessagePackDecoder.decode(BinaryFixture.data("ca3fc00000")) == .float(1.5))
        #expect(try MessagePackDecoder.decode(BinaryFixture.data("cb3fb999999999999a")) == .double(0.1))
    }

    @Test("A value cut short says where it ends")
    func truncated() {
        #expect(throws: BinaryValueDecodeError(kind: .unexpectedEnd, offset: 6)) {
            try MessagePackDecoder.decode(BinaryFixture.data("82a7636f6d70"))
        }
    }

    @Test("The reserved byte 0xC1 is refused")
    func reservedByte() {
        #expect(throws: BinaryValueDecodeError(kind: .invalidByte(0xC1), offset: 1)) {
            try MessagePackDecoder.decode(BinaryFixture.data("91c1"))
        }
    }

    @Test("Bytes after the value are refused")
    func trailingBytes() {
        #expect(throws: BinaryValueDecodeError(kind: .trailingBytes(1), offset: 1)) {
            try MessagePackDecoder.decode(BinaryFixture.data("c0c0"))
        }
    }

    @Test("A count larger than the bytes left is refused before anything is reserved")
    func forgedCount() {
        #expect(throws: BinaryValueDecodeError.self) {
            try MessagePackDecoder.decode(BinaryFixture.data("ddffffffff"))
        }
    }

    @Test("A budgeted decode stops and marks where")
    func budget() throws {
        let value = try MessagePackDecoder.decode(
            BinaryFixture.data("dc0014000102030405060708090a0b0c0d0e0f10111213"),
            maxValues: 5
        )
        #expect(MessagePackTextWriter.json(value, pretty: false) == "[0,1,2,3,…]")
    }

    @Test("The tree badges bin, ext and timestamp values")
    func treeBadges() throws {
        let value = try MessagePackDecoder.decode(BinaryFixture.data("93c4020102d505a1b2d6ff6553f100"))
        let tree = MessagePackTreeBuilder.build(from: value, formats: BinaryFixture.english)
        #expect(tree.children.map { $0.badgeLabel } == ["bin", "ext", "time"])
        #expect(tree.children.map { $0.copyableValue } == ["0x0102", "ext(5) 0xA1B2", "2023-11-14T22:13:20Z"])
        #expect(tree.copyableValue == #"["0x0102","ext(5) 0xA1B2","2023-11-14T22:13:20Z"]"#)
    }

    @Test("Pretty text indents like the JSON viewer")
    func pretty() throws {
        let value = try MessagePackDecoder.decode(BinaryFixture.data("8201a36f6e650291c3"))
        #expect(MessagePackTextWriter.json(value, pretty: true) == "{\n  \"1\": \"one\",\n  \"2\": [\n    true\n  ]\n}")
    }
}

enum BinaryFixture {
    static func data(_ hex: String) -> Data {
        let digits = Array(hex.utf8)
        return Data(stride(from: 0, to: digits.count - 1, by: 2).map { index in
            UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) ?? 0
        })
    }

    static let english = TreeSummaryFormats(
        keys: .init(one: "1 key", many: "%lld keys"),
        items: .init(one: "1 item", many: "%lld items"),
        properties: .init(one: "1 property", many: "%lld properties"),
        fields: .init(one: "1 field", many: "%lld fields")
    )
}
