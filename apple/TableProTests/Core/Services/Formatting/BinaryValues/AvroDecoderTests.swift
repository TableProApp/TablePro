//
//  AvroDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Fixtures written by fastavro 1.13.1, `schemaless_writer(buffer, parse_schema(schema), record)`.
struct AvroDecoderTests {
    private static let userSchema = #"{"type":"record","name":"User","namespace":"com.example","fields":["#
        + #"{"name":"id","type":"long"},{"name":"name","type":"string"},{"name":"email","type":["null","string"]},"#
        + #"{"name":"active","type":"boolean"},{"name":"score","type":"double"},{"name":"ratio","type":"float"},"#
        + #"{"name":"tags","type":{"type":"array","items":"string"}},{"name":"attrs","type":{"type":"map","values":"int"}},"#
        + #"{"name":"kind","type":{"type":"enum","name":"Kind","symbols":["A","B","C"]}},"#
        + #"{"name":"hash","type":{"type":"fixed","name":"Hash","size":4}},{"name":"raw","type":"bytes"},"#
        + #"{"name":"nothing","type":"null"}]}"#

    private static let logicalSchema = #"{"type":"record","name":"Logical","fields":["#
        + #"{"name":"id","type":{"type":"string","logicalType":"uuid"}},"#
        + #"{"name":"day","type":{"type":"int","logicalType":"date"}},"#
        + #"{"name":"tms","type":{"type":"int","logicalType":"time-millis"}},"#
        + #"{"name":"tus","type":{"type":"long","logicalType":"time-micros"}},"#
        + #"{"name":"tsms","type":{"type":"long","logicalType":"timestamp-millis"}},"#
        + #"{"name":"tsus","type":{"type":"long","logicalType":"timestamp-micros"}},"#
        + #"{"name":"local","type":{"type":"long","logicalType":"local-timestamp-millis"}},"#
        + #"{"name":"price","type":{"type":"bytes","logicalType":"decimal","precision":10,"scale":2}},"#
        + #"{"name":"weight","type":{"type":"fixed","name":"Weight","size":8,"logicalType":"decimal","precision":12,"scale":3}}]}"#

    private static func json(_ hex: String, schema: String) throws -> String {
        let message = try AvroDecoder.decode(BinaryFixture.data(hex), schema: try AvroSchema.parse(schema))
        return MessagePackTextWriter.json(message.value, pretty: false)
    }

    @Test("A record with every primitive and complex type")
    func record() throws {
        let hex = "9593d89fee470e416e6e204c6565021e616e6e406578616d706c652e636f6d01000000000000f83f000080be0402610662c3a9"
            + "000402780202790300040102feff040010"
        let expected = #"{"id":-1234567890123,"name":"Ann Lee","email":"ann@example.com","active":true,"score":1.5,"#
            + #""ratio":-0.25,"tags":["a","bé"],"attrs":{"x":1,"y":-2},"kind":"C","hash":"0x0102FEFF","raw":"0x0010","#
            + #""nothing":null}"#
        #expect(try Self.json(hex, schema: Self.userSchema) == expected)
    }

    @Test("A datum that starts with zero bytes reads as it is, not as a Kafka frame")
    func leadingZeroDatum() throws {
        let message = try AvroDecoder.decode(
            BinaryFixture.data(String(repeating: "00", count: 24)),
            schema: try AvroSchema.parse(Self.userSchema)
        )
        #expect(message.schemaID == nil)
        let expected = #"{"id":0,"name":"","email":null,"active":false,"score":0.0,"ratio":0.0,"tags":[],"attrs":{},"#
            + #""kind":"A","hash":"0x00000000","raw":"0x","nothing":null}"#
        #expect(MessagePackTextWriter.json(message.value, pretty: false) == expected)
    }

    @Test("A Kafka value keeps its schema ID and decodes past the prefix")
    func confluentFrame() throws {
        let hex = "000000002a0e024b000100000000000000400000803f0202740002026b06000261626364027f"
        let message = try AvroDecoder.decode(BinaryFixture.data(hex), schema: try AvroSchema.parse(Self.userSchema))
        #expect(message.schemaID == 42)
        let expected = #"{"id":7,"name":"K","email":null,"active":true,"score":2.0,"ratio":1.0,"tags":["t"],"attrs":{"k":3},"#
            + #""kind":"B","hash":"0x61626364","raw":"0x7F","nothing":null}"#
        #expect(MessagePackTextWriter.json(message.value, pretty: false) == expected)
    }

    @Test("Logical types render as the values they stand for")
    func logicalTypes() throws {
        let hex = "4836636364373830632d626162612d313032362d393536342d35623863363536303234646296b502aab2992bcaa1c4de1b"
            + "aa82e1e9c163018ef6e0e9c16306fe1dc00000000000003039"
        let expected = #"{"id":"6ccd780c-baba-1026-9564-5b8c656024db","day":"2024-03-05","tms":"12:34:56.789","#
            + #""tus":"01:02:03.004005","tsms":"2024-03-05T12:34:56.789Z","tsus":"1969-12-31T23:59:59.999999Z","#
            + #""local":"2024-03-05T12:34:56.007","price":"-1234.56","weight":"12.345"}"#
        #expect(try Self.json(hex, schema: Self.logicalSchema) == expected)
    }

    @Test("A record that refers to itself by name")
    func recursiveRecord() throws {
        let schema = #"{"type":"record","name":"Node","namespace":"com.example.list","fields":["#
            + #"{"name":"value","type":"int"},{"name":"next","type":["null","Node"]}]}"#
        #expect(try Self.json("020204020600", schema: schema)
            == #"{"value":1,"next":{"value":2,"next":{"value":3,"next":null}}}"#)
    }

    @Test("A bare long at its minimum, and a union of several branches")
    func primitivesAndUnions() throws {
        #expect(try Self.json("ffffffffffffffffff01", schema: #""long""#) == "-9223372036854775808")
        let union = #"{"type":"array","items":["int","string",{"type":"array","items":"long"}]}"#
        #expect(try Self.json("06000a020273040402010000", schema: union) == #"[5,"s",[1,-1]]"#)
    }

    @Test("An array block with a negative count carries its byte size")
    func negativeBlockCount() throws {
        #expect(try Self.json("0304020400", schema: #"{"type":"array","items":"int"}"#) == "[1,2]")
    }

    @Test("An array of nulls holds more items than bytes, up to a limit")
    func zeroByteItems() throws {
        let nulls = #"{"type":"array","items":"null"}"#
        #expect(try Self.json("0400", schema: nulls) == "[null,null]")
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(BinaryFixture.data("feffffffffffffffff0100"), schema: try AvroSchema.parse(nulls))
        }
        #expect(error?.kind == .tooLarge)
    }

    @Test("A decimal without a usable precision and scale reads as its bytes")
    func invalidDecimalFallsBack() throws {
        for annotation in [#""scale":2"#, #""precision":2,"scale":3"#, #""precision":100000000,"scale":100000000"#] {
            let schema = #"{"type":"bytes","logicalType":"decimal","# + annotation + "}"
            #expect(try Self.json("0230", schema: schema) == #""0x30""#, "\(annotation)")
        }
    }

    @Test("Decimals of any width keep their sign and scale")
    func decimalText() {
        #expect(AvroLogicalRendering.decimalText(unscaled: [0x00], scale: 2) == "0.00")
        #expect(AvroLogicalRendering.decimalText(unscaled: [0xFF], scale: 3) == "-0.001")
        #expect(AvroLogicalRendering.decimalText(unscaled: [0x30, 0x39], scale: 0) == "12345")
        #expect(AvroLogicalRendering.decimalText(unscaled: [0x80] + Array(repeating: 0, count: 15), scale: 0)
            == "-170141183460469231731687303715884105728")
    }

    @Test("A value that does not fit the schema names what is wrong and where")
    func brokenValues() throws {
        let schema = try AvroSchema.parse(Self.userSchema)
        let cases: [(hex: String, kind: BinaryValueDecodeError.Kind)] = [
            ("02", .unexpectedEnd),
            ("020e416e6e", .unexpectedEnd),
            ("02000600", .indexOutOfRange(3)),
            ("0201", .invalidLength),
            ("02000002", .invalidByte(0x02)),
        ]
        for testCase in cases {
            let error = #expect(throws: BinaryValueDecodeError.self, "\(testCase.hex)") {
                try AvroDecoder.decode(BinaryFixture.data(testCase.hex), schema: schema)
            }
            #expect(error?.kind == testCase.kind, "\(testCase.hex)")
        }
        let int = try AvroSchema.parse(#""int""#)
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(BinaryFixture.data("8080808020"), schema: int)
        }
        #expect(error?.kind == .integerOutOfRange)
        let trailing = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(BinaryFixture.data("0202"), schema: int)
        }
        #expect(trailing?.kind == .trailingBytes(1))
    }

    @Test("A schema that is not one says why")
    func brokenSchemas() {
        for text in [
            "not json",
            #"{"type":"record","name":"R"}"#,
            #"{"type":"record","name":"R","fields":[{"name":"x","type":"Missing"}]}"#,
            #"{"type":"enum","name":"E"}"#,
            #"{"type":"fixed","name":"F"}"#,
            #"{"type":"array"}"#,
            "42",
        ] {
            #expect(throws: AvroSchemaError.self, "\(text)") { try AvroSchema.parse(text) }
        }
    }

    @Test("A named type resolves inside its namespace and by full name")
    func namespaces() throws {
        let schema = try AvroSchema.parse(
            #"{"type":"record","name":"Outer","namespace":"a.b","fields":["#
                + #"{"name":"e","type":{"type":"enum","name":"Color","symbols":["RED"]}},"#
                + #"{"name":"f","type":"Color"},{"name":"g","type":"a.b.Color"}]}"#
        )
        #expect(schema.namedTypes["a.b.Color"] == .enumeration(name: "a.b.Color", symbols: ["RED"]))
        let value = try AvroDecoder.decode(BinaryFixture.data("000000"), schema: schema).value
        #expect(MessagePackTextWriter.json(value, pretty: false) == #"{"e":"RED","f":"RED","g":"RED"}"#)
    }
}
