//
//  AvroDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// Fixtures written by fastavro, `schemaless_writer(buffer, parse_schema(schema), record)`: 1.13.1, and 1.12.2 for
// the named decimal, the padded decimal and the nanosecond timestamps.
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
        #expect(message.framing == nil)
        let expected = #"{"id":0,"name":"","email":null,"active":false,"score":0.0,"ratio":0.0,"tags":[],"attrs":{},"#
            + #""kind":"A","hash":"0x00000000","raw":"0x","nothing":null}"#
        #expect(MessagePackTextWriter.json(message.value, pretty: false) == expected)
    }

    @Test("A Kafka value keeps its schema ID and decodes past the prefix")
    func confluentFrame() throws {
        let hex = "000000002a0e024b000100000000000000400000803f0202740002026b06000261626364027f"
        let message = try AvroDecoder.decode(BinaryFixture.data(hex), schema: try AvroSchema.parse(Self.userSchema))
        #expect(message.framing == .confluent(schemaID: 42))
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

    @Test("Items that take no bytes count toward the limit across every block, nested ones included")
    func zeroByteItemsAcrossBlocks() throws {
        let nested = try AvroSchema.parse(#"{"type":"array","items":{"type":"array","items":"null"}}"#)
        let fourThousandNulls = "c03e00"
        #expect(throws: Never.self) {
            try AvroDecoder.decode(BinaryFixture.data("04" + String(repeating: fourThousandNulls, count: 2) + "00"), schema: nested)
        }
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(BinaryFixture.data("d804" + String(repeating: fourThousandNulls, count: 300) + "00"), schema: nested)
        }
        #expect(error?.kind == .tooLarge)
    }

    @Test("A cell's budget stops building, not reading, so it finds the Kafka frame the viewer finds")
    func budgetKeepsTheFramingDecision() throws {
        let schema = try AvroSchema.parse(
            #"{"type":"record","name":"Six","fields":[{"name":"a","type":"long"},{"name":"b","type":"long"},"#
                + #"{"name":"c","type":"long"},{"name":"d","type":"long"},{"name":"e","type":"long"},{"name":"f","type":"long"}]}"#
        )
        let framed = BinaryFixture.data("0000000005" + "020406080a0c")
        let full = try AvroDecoder.decode(framed, schema: schema)
        #expect(full.framing == .confluent(schemaID: 5))
        #expect(MessagePackTextWriter.json(full.value, pretty: false) == #"{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6}"#)
        let budgeted = try AvroDecoder.decode(framed, schema: schema, maxValues: 3)
        #expect(budgeted.framing == .confluent(schemaID: 5))
        #expect(MessagePackTextWriter.json(budgeted.value, pretty: false) == #"{"a":1,"b":2,"c":…}"#)
    }

    @Test("Fingerprints match Avro Java's CRC-64-AVRO of the Parsing Canonical Form")
    func fingerprints() throws {
        #expect(try AvroSchema.parse(#""int""#).fingerprint == 0x7275_D51A_3F39_5C8F)
        #expect(try AvroSchema.parse(#"{"type":"string"}"#).fingerprint == 0x8F01_4872_6345_03C7)
        #expect(try AvroSchema.parse(#""bytes""#).fingerprint == 0x4FC0_16DA_C320_1965)
        let record = #"{"type":"record","name":"R","doc":"ignored","fields":[{"name":"a","type":"long"},"#
            + #"{"name":"b","type":{"type":"string","logicalType":"uuid"}}]}"#
        #expect(try AvroSchema.parse(record).fingerprint == 0xD99C_4645_DD9B_2051)
        let payment = #"{"type":"record","name":"Payment","namespace":"com.example","fields":[{"name":"id","type":"string"},"#
            + #"{"name":"amount","type":{"type":"fixed","name":"Money","size":8,"logicalType":"decimal","precision":12,"scale":2}},"#
            + #"{"name":"fee","type":["null","Money"]},{"name":"kind","type":{"type":"enum","name":"Kind","symbols":["A","B"]}},"#
            + #"{"name":"tags","type":{"type":"map","values":{"type":"array","items":"int"}}}]}"#
        let parsed = try AvroSchema.parse(payment)
        #expect(AvroSchema.canonicalForm(parsed.root) == #"{"name":"com.example.Payment","type":"record","fields":["#
            + #"{"name":"id","type":"string"},{"name":"amount","type":{"name":"com.example.Money","type":"fixed","size":8}},"#
            + #"{"name":"fee","type":["null","com.example.Money"]},"#
            + #"{"name":"kind","type":{"name":"com.example.Kind","type":"enum","symbols":["A","B"]}},"#
            + #"{"name":"tags","type":{"type":"map","values":{"type":"array","items":"int"}}}]}"#)
        #expect(parsed.fingerprint == 0x51D2_8FF2_5F71_BF64)
    }

    @Test("A single-object encoded value is read past its header when the fingerprint is the schema's, and refused when not")
    func singleObjectEncoding() throws {
        let schema = try AvroSchema.parse(
            #"{"type":"record","name":"R","fields":[{"name":"a","type":"long"},{"name":"b","type":"string"}]}"#
        )
        let data = BinaryFixture.data("c301" + "51209bdd45469cd9" + "020278")
        let message = try AvroDecoder.decode(data, schema: schema)
        #expect(message.framing == .singleObject(fingerprint: 0xD99C_4645_DD9B_2051))
        #expect(MessagePackTextWriter.json(message.value, pretty: false) == #"{"a":1,"b":"x"}"#)

        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(data, schema: try AvroSchema.parse(#""long""#))
        }
        #expect(error?.kind == .otherSchema(fingerprint: 0xD99C_4645_DD9B_2051))
    }

    @Test("A Kafka value of a bytes schema is the bytes themselves, with no length in front")
    func confluentBytes() throws {
        let message = try AvroDecoder.decode(BinaryFixture.data("0000000007dead"), schema: try AvroSchema.parse(#""bytes""#))
        #expect(message.framing == .confluent(schemaID: 7))
        #expect(message.value == .binary(Data([0xDE, 0xAD])))
        let decimal = try AvroSchema.parse(#"{"type":"bytes","logicalType":"decimal","precision":4,"scale":2}"#)
        #expect(try AvroDecoder.decode(BinaryFixture.data("000000000704d2"), schema: decimal).value == .string("12.34"))
    }

    @Test("Records that take no bytes, nested two to a level, are refused rather than walked exponentially")
    func zeroByteRecordsDoNotExpand() throws {
        var definitions = [#"{"type":"record","name":"R0","fields":[]}"#]
        for level in 1...30 {
            definitions.append(#"{"type":"record","name":"R"# + "\(level)" + #"","fields":[{"name":"a","type":"R"#
                + "\(level - 1)" + #""},{"name":"b","type":"R"# + "\(level - 1)" + #""}]}"#)
        }
        let fields = definitions.enumerated().map { #"{"name":"f"# + "\($0.offset)" + #"","type":"# + $0.element + "}" }
        let holder = #"{"type":"record","name":"Holder","fields":["# + fields.dropLast().joined(separator: ",") + "]}"
        let schema = try AvroSchema.parse(#"{"type":"array","items":{"type":"record","name":"Wrap","fields":[{"name":"h","type":"#
            + holder + #"},{"name":"r","type":"# + definitions[30] + "}]}}")
        #expect(try AvroDecoder.decode(Data([0x00]), schema: schema).value == .array([]))
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(Data([0x02, 0x00]), schema: schema)
        }
        #expect(error?.kind == .tooLarge)
    }

    @Test("A grid cell reads a value only so far, then leaves it to the viewer")
    func cellReadLimit() throws {
        let booleans = try AvroSchema.parse(#"{"type":"array","items":"boolean"}"#)
        let data = Data([0x90, 0x03]) + Data(repeating: 0x01, count: 200) + Data([0x00])
        #expect(throws: Never.self) { try AvroDecoder.decode(data, schema: booleans, maxValues: 10) }
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(data, schema: booleans, maxValues: 10, maxValuesRead: 100)
        }
        #expect(error?.kind == .tooLarge)
    }

    @Test("A schema that chains thousands of named records parses without walking the chain")
    func longNamedChain() throws {
        var records = [#"{"type":"record","name":"N0","fields":[]}"#]
        for index in 1...20_000 {
            records.append(#"{"type":"record","name":"N"# + "\(index)" + #"","fields":[{"name":"p","type":"N"# + "\(index - 1)" + #""}]}"#)
        }
        let schema = try AvroSchema.parse("[" + records.joined(separator: ",") + "]")
        #expect(schema.takesNoBytes(.named("N20000")))
        #expect(!schema.takesNoBytes(.union([.null])))
    }

    @Test("A huge zero-byte block after a small one is refused, not added up until it overflows")
    func zeroByteCountOverflow() throws {
        let nulls = try AvroSchema.parse(#"{"type":"array","items":"null"}"#)
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try AvroDecoder.decode(BinaryFixture.data("c801feffffffffffffffff0100"), schema: nulls)
        }
        #expect(error?.kind == .tooLarge)
    }

    @Test("A size, precision or scale that is not a whole number is refused, as Avro's parser refuses it")
    func strictIntegerAttributes() throws {
        #expect(throws: AvroSchemaError.self) { try AvroSchema.parse(#"{"type":"fixed","name":"F","size":true}"#) }
        #expect(throws: AvroSchemaError.self) { try AvroSchema.parse(#"{"type":"fixed","name":"F","size":4.5}"#) }
        #expect(try Self.json("0230", schema: #"{"type":"bytes","logicalType":"decimal","precision":4.0}"#) == #""0x30""#)
        #expect(try Self.json("0230", schema: #"{"type":"bytes","logicalType":"decimal","precision":4,"scale":true}"#) == #""0x30""#)
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
        #expect(AvroDecimal.text(unscaled: [0x00], scale: 2) == "0.00")
        #expect(AvroDecimal.text(unscaled: [0xFF], scale: 3) == "-0.001")
        #expect(AvroDecimal.text(unscaled: [0x30, 0x39], scale: 0) == "12345")
        #expect(AvroDecimal.text(unscaled: [0x80] + Array(repeating: 0, count: 15), scale: 0)
            == "-170141183460469231731687303715884105728")
        #expect(AvroDecimal.text(unscaled: [0x0D, 0xE0, 0xB6, 0xB3, 0xA7, 0x64, 0x00, 0x00], scale: 18) == "1.000000000000000000")
        #expect(AvroDecimal.text(unscaled: [0x3B, 0x9A, 0xCA, 0x00], scale: 0) == "1000000000")
    }

    @Test("A decimal reads as its bytes once its significant width passes what its precision holds")
    func decimalWidthFollowsPrecision() throws {
        let schema = #"{"type":"bytes","logicalType":"decimal","precision":4,"scale":2}"#
        #expect(try Self.json("0404d2", schema: schema) == #""12.34""#)
        #expect(try Self.json("08000004d2", schema: schema) == #""12.34""#)
        #expect(try Self.json("067fffff", schema: schema) == #""0x7FFFFF""#)
        let padded = #"{"type":"fixed","name":"Wide","size":16,"logicalType":"decimal","precision":4,"scale":2}"#
        #expect(try Self.json("000000000000000000000000000004d2", schema: padded) == #""12.34""#)
        #expect(AvroDecimal.maxBytes(precision: 38) == 16)
        #expect(AvroDecimal.maxPrecision(bytes: 16) == 38)
    }

    @Test("A fixed's decimal precision past what its size holds is ignored, as Avro's reader does")
    func fixedDecimalPrecisionFitsSize() throws {
        let schema = #"{"type":"fixed","name":"Small","size":2,"logicalType":"decimal","precision":5,"scale":0}"#
        #expect(try Self.json("04d2", schema: schema) == #""0x04D2""#)
    }

    @Test("A named fixed keeps its logical type where it is referred to by name")
    func namedLogicalType() throws {
        let schema = #"{"type":"record","name":"Prices","fields":["#
            + #"{"name":"a","type":{"type":"fixed","name":"Money","size":8,"logicalType":"decimal","precision":12,"scale":2}},"#
            + #"{"name":"b","type":"Money"}]}"#
        #expect(try Self.json("00000000000004d2fffffffffffffffb", schema: schema) == #"{"a":"12.34","b":"-0.05"}"#)
    }

    @Test("Nanosecond timestamps and durations render as values")
    func nanosAndDuration() throws {
        let nanos = #"{"type":"record","name":"N","fields":["#
            + #"{"name":"ts","type":{"type":"long","logicalType":"timestamp-nanos"}},"#
            + #"{"name":"lts","type":{"type":"long","logicalType":"local-timestamp-nanos"}}]}"#
        #expect(try Self.json("aab4aed8c7bfce972faab4aed8c7bfce972f", schema: nanos)
            == #"{"ts":"2023-11-14T22:13:20.123456789Z","lts":"2023-11-14T22:13:20.123456789"}"#)
        let duration = #"{"type":"fixed","name":"D","size":12,"logicalType":"duration"}"#
        #expect(try Self.json("0100000002000000bc0b0000", schema: duration) == #""P1M2DT3.004S""#)
        #expect(try Self.json("000000000000000000000000", schema: duration) == #""PT0S""#)
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
            #"{"type":"record","name":"R","fields":[{"name":"a","type":{"type":"enum","name":"R","symbols":["X"]}}]}"#,
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
        #expect(schema.displayName == "Outer")
        let value = try AvroDecoder.decode(BinaryFixture.data("000000"), schema: schema).value
        #expect(MessagePackTextWriter.json(value, pretty: false) == #"{"e":"RED","f":"RED","g":"RED"}"#)
    }
}
