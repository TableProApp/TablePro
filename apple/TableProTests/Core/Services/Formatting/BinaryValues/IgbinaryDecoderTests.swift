//
//  IgbinaryDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// Fixtures from igbinary 3.2.17RC1 on PHP 8.3: igbinary_serialize($value) beside serialize($value).
struct IgbinaryDecoderTests {
    private static let fixtures: [(name: String, hex: String, serialized: String)] = [
        ("null", "0000000200", #"N;"#),
        ("true", "0000000205", #"b:1;"#),
        ("false", "0000000204", #"b:0;"#),
        ("small int", "000000020607", #"i:7;"#),
        ("negative int", "0000000209012c", #"i:-300;"#),
        ("32-bit int", "000000020a00011170", #"i:70000;"#),
        ("64-bit int", "0000000220000000012a05f200", #"i:5000000000;"#),
        ("PHP_INT_MAX", "00000002207fffffffffffffff", #"i:9223372036854775807;"#),
        ("PHP_INT_MIN", "00000002218000000000000000", #"i:-9223372036854775808;"#),
        ("empty string", "000000020d", #"s:0:"";"#),
        ("UTF-8 string", "00000002110d68c3a96c6c6f2077c3b6726c64", #"s:13:"héllo wörld";"#),
        (
            "list of scalars",
            "000000021406060006010601060206021105746872656506030c4012000000000000060400060504",
            #"a:6:{i:0;i:1;i:1;i:2;i:2;s:5:"three";i:3;d:4.5;i:4;N;i:5;b:0;}"#
        ),
        (
            "nested map with int keys",
            "00000002140511046e616d651103416e6e11047461677314020600110161060111016211046d65746114020e00110569"
                + "6e6e657211016e0701060a110374656e070511036e6567",
            #"a:5:{s:4:"name";s:3:"Ann";s:4:"tags";a:2:{i:0;s:1:"a";i:1;s:1:"b";}s:4:"meta";a:2:{s:4:"na"#
                + #"me";s:5:"inner";s:1:"n";i:-1;}i:10;s:3:"ten";i:-5;s:3:"neg";}"#
        ),
        (
            "repeated strings by ID",
            "00000002140506001105616c706861060111046265746106020e0006030e0106040e00",
            #"a:5:{i:0;s:5:"alpha";i:1;s:4:"beta";i:2;s:5:"alpha";i:3;s:4:"beta";i:4;s:5:"alpha";}"#
        ),
        (
            "keys and values share string IDs",
            "00000002140311016b1101760e010e0011017a14010e000e01",
            #"a:3:{s:1:"k";s:1:"v";s:1:"v";s:1:"k";s:1:"z";a:1:{s:1:"k";s:1:"v";}}"#
        ),
        (
            "object with every visibility",
            "000000021705506f696e74140311017806011104002a00790602110800506f696e74007a0603",
            #"O:5:"Point":3:{s:1:"x";i:1;s:4:"\#u{0}*\#u{0}y";i:2;s:8:"\#u{0}Point\#u{0}z";i:3;}"#
        ),
        ("stdClass", "000000021708737464436c617373140211016106011101621401060005", #"O:8:"stdClass":2:{s:1:"a";i:1;s:1:"b";a:1:{i:0;b:1;}}"#),
        ("empty stdClass", "000000021708737464436c6173731400", #"O:8:"stdClass":0:{}"#),
        ("enum case", "00000002170453756974271106486561727473", #"E:11:"Suit:Hearts";"#),
        (
            "repeated enum case",
            "00000002140406001704537569742711064865617274730601220106021a0027110653706164657306030601",
            #"a:4:{i:0;E:11:"Suit:Hearts";i:1;r:2;i:2;E:11:"Suit:Spades";i:3;i:1;}"#
        ),
        (
            "PHP reference to an enum case",
            "000000021403060025170453756974271106486561727473060125220106020602",
            #"a:3:{i:0;E:11:"Suit:Hearts";i:1;R:2;i:2;i:2;}"#
        ),
        (
            "repeated object",
            "00000002140306001705506f696e74140311017806011104002a00790602110800506f696e74007a0603060122010602"
                + "2201",
            #"a:3:{i:0;O:5:"Point":3:{s:1:"x";i:1;s:4:"\#u{0}*\#u{0}y";i:2;s:8:"\#u{0}Point\#u{0}z";i:3;}i:1;r:2;i:2;r:2;}"#
        ),
        (
            "__serialize object repeated",
            "00000002140306001703426f78140111017606050601220106020603",
            #"a:3:{i:0;O:3:"Box":1:{s:1:"v";i:5;}i:1;r:2;i:2;i:3;}"#
        ),
        ("Serializable object repeated", "000000021403060017034f6c641d036162630601220106020604", #"a:3:{i:0;C:3:"Old":3:{abc}i:1;r:2;i:2;i:4;}"#),
        ("object holding itself", "000000021708737464436c6173731401110473656c662200", #"O:8:"stdClass":1:{s:4:"self";r:1;}"#),
        ("PHP reference inside an array repeated by value", "00000002140206001401060025060106010101", #"a:2:{i:0;a:1:{i:0;i:1;}i:1;a:1:{i:0;R:3;}}"#),
        (
            "PHP reference to an object, then objects",
            "0000000214040600251708737464436c6173731400060125220106021a00140006032202",
            #"a:4:{i:0;O:8:"stdClass":0:{}i:1;R:2;i:2;O:8:"stdClass":0:{}i:3;r:3;}"#
        ),
        (
            "PHP reference to an array",
            "00000002140306002514010600060106012501010602140106000601",
            #"a:3:{i:0;a:1:{i:0;i:1;}i:1;R:2;i:2;a:1:{i:0;i:1;}}"#
        ),
        (
            "PHP reference inside an object",
            "00000002140206001708737464436c617373140211016125110373747211016225010206012201",
            #"a:2:{i:0;O:8:"stdClass":2:{s:1:"a";s:3:"str";s:1:"b";R:3;}i:1;r:2;}"#
        ),
        (
            "object and its reference in an array repeated by value",
            "0000000214020600140206001708737464436c6173731400060125220206010101",
            #"a:2:{i:0;a:2:{i:0;O:8:"stdClass":0:{}i:1;R:3;}i:1;a:2:{i:0;r:3;i:1;R:3;}}"#
        ),
        ("scalar reference, then its value", "0000000214030600251102616106010e000602250101", #"a:3:{i:0;s:2:"aa";i:1;s:2:"aa";i:2;R:2;}"#),
        ("PHP reference to null", "000000021402060025000601250101", #"a:2:{i:0;N;i:1;R:2;}"#),
        (
            "array repeated by value",
            "0000000214030600140111016b1101760601010106020101",
            #"a:3:{i:0;a:1:{s:1:"k";s:1:"v";}i:1;a:1:{s:1:"k";s:1:"v";}i:2;a:1:{s:1:"k";s:1:"v";}}"#
        ),
        (
            "arrays repeated by value inside one another",
            "000000021402060014020600140111017806010601010206010101",
            #"a:2:{i:0;a:2:{i:0;a:1:{s:1:"x";i:1;}i:1;a:1:{s:1:"x";i:1;}}i:1;a:2:{i:0;a:1:{s:1:"x";i:1;}"#
                + #"i:1;a:1:{s:1:"x";i:1;}}}"#
        ),
        (
            "object inside an array repeated by value",
            "0000000214030600140206001705506f696e74140311017806011104002a00790602110800506f696e74007a06030601"
                + "06020601010106022202",
            #"a:3:{i:0;a:2:{i:0;O:5:"Point":3:{s:1:"x";i:1;s:4:"\#u{0}*\#u{0}y";i:2;s:8:"\#u{0}Point\#u{0}z";i:3;}i:1;i:2;}i"#
                + #":1;a:2:{i:0;r:3;i:1;i:2;}i:2;r:3;}"#
        ),
        (
            "floats",
            "00000002140e06000c800000000000000006010c430c6bf52634000006020c4341c37937e0800006030c4376345785d8"
                + "a00006040c3fb999999999999a06050c3ee4f8b588e368f106060c3f1a36e2eb1c432d06070c3e8421f5f40d83760608"
                + "0c40fe240c9fbe76c906090c0000000000000001060a0c7fefffffffffffff060b0c4345ee2a2eb5a5c4060c0c7ff000"
                + "0000000000060d0cfff0000000000000",
            #"a:14:{i:0;d:-0;i:1;d:1000000000000000;i:2;d:10000000000000000;i:3;d:1.0E+17;i:4;d:0.1;i:5;"#
                + #"d:1.0E-5;i:6;d:0.0001;i:7;d:1.5E-7;i:8;d:123456.789;i:9;d:5.0E-324;i:10;d:1.79769313486231"#
                + #"57E+308;i:11;d:12345678901234568;i:12;d:INF;i:13;d:-INF;}"#
        ),
        (
            "ArrayObject, whose members have integer keys",
            "00000002170b41727261794f626a65637414040600060006011402060006010601060206021400060300",
            #"O:11:"ArrayObject":4:{i:0;i:0;i:1;a:2:{i:0;i:1;i:1;i:2;}i:2;a:0:{}i:3;N;}"#
        ),
        ("__serialize list", "000000021401060017074c697374426f7814020600060a0601110178", #"a:1:{i:0;O:7:"ListBox":2:{i:0;i:10;i:1;s:1:"x";}}"#),
    ]

    @Test("Each fixture decodes to what serialize() wrote, numbering, r and R included")
    func fixturesMatchSerialize() throws {
        for fixture in Self.fixtures {
            let decoded = try IgbinaryDecoder.decode(BinaryFixture.data(fixture.hex))
            #expect(PhpSerializeWriter.text(decoded) == fixture.serialized, "\(fixture.name)")
            #expect(decoded == PhpSerializeParser.parse(fixture.serialized), "\(fixture.name)")
        }
    }

    @Test("A string that is not UTF-8 keeps its bytes, and its length is the byte count serialize() writes")
    func binaryStrings() throws {
        let value = try IgbinaryDecoder.decode(BinaryFixture.data("00000002110600ff80616263"))
        #expect(value == .binaryString(Data([0x00, 0xFF, 0x80, 0x61, 0x62, 0x63])))
        #expect(PhpSerializeWriter.text(value) == Self.latin1("733a363a2200ff80616263223b"))

        let keyed = try IgbinaryDecoder.decode(BinaryFixture.data("0000000214021102fffe06011103fffe781101ff"))
        #expect(keyed == .array([
            PhpKeyValue(key: .binaryString(Data([0xFF, 0xFE])), value: .int(1)),
            PhpKeyValue(key: .binaryString(Data([0xFF, 0xFE, 0x78])), value: .binaryString(Data([0xFF]))),
        ]))
        #expect(
            PhpSerializeWriter.text(keyed)
                == Self.latin1("613a323a7b733a323a22fffe223b693a313b733a333a22fffe78223b733a313a22ff223b7d")
        )
    }

    @Test("A Serializable payload that is not UTF-8 keeps its bytes and its byte count")
    func binarySerializablePayload() throws {
        let value = try IgbinaryDecoder.decode(BinaryFixture.data("0000000217034f6c641d01ff"))
        #expect(value == .binarySerializable(className: "Old", payload: Data([0xFF])))
        #expect(PhpSerializeWriter.text(value) == #"C:3:"Old":1:{"# + "\u{FF}}")
    }

    @Test("A string of 300 bytes uses the 16-bit length")
    func longString() throws {
        let hex = "0000000212012c" + String(repeating: "61", count: 300)
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data(hex)) == .string(String(repeating: "a", count: 300)))
    }

    @Test("Arrays nested by value forty deep are refused rather than expanded")
    func exponentialCopiesAreRefused() {
        func level(_ depth: Int, of total: Int) -> String {
            guard depth > 0 else { return "14020600060106010601" }
            return "14020600" + level(depth - 1, of: total) + "060101" + String(format: "%02x", total - depth + 1)
        }
        let error = #expect(throws: BinaryValueDecodeError.self) {
            try IgbinaryDecoder.decode(BinaryFixture.data("00000002" + level(40, of: 40)))
        }
        #expect(error?.kind == .tooLarge)
        #expect(throws: Never.self) { try IgbinaryDecoder.decode(BinaryFixture.data("00000002" + level(3, of: 3))) }
    }

    @Test("A long string repeated by ID past the limit is refused")
    func repeatedLongStringIsRefused() {
        var hex = "0000000215" + String(format: "%04x", 6_000) + "080000" + "1300001000" + String(repeating: "61", count: 4_096)
        for index in 1..<6_000 {
            hex += "08" + String(format: "%04x", index) + "0e00"
        }
        let error = #expect(throws: BinaryValueDecodeError.self) { try IgbinaryDecoder.decode(BinaryFixture.data(hex)) }
        #expect(error?.kind == .tooLarge)
    }

    @Test("Strings inside an array repeated by value count toward the string limit")
    func repeatedArrayStringsAreRefused() {
        let text = Data(repeating: 0x61, count: 1_000_000)
        func value(copies: Int) -> Data {
            var data = Data([0, 0, 0, 2, 0x15]) + Self.bigEndian(UInt16(copies + 1))
            data += Data([0x06, 0x00, 0x14, 0x01, 0x06, 0x00, 0x13]) + Self.bigEndian(UInt32(text.count)) + text
            for index in 1...copies {
                data += Data([0x08]) + Self.bigEndian(UInt16(index)) + Data([0x01, 0x01])
            }
            return data
        }
        #expect(throws: Never.self) { try IgbinaryDecoder.decode(value(copies: 10)) }
        let error = #expect(throws: BinaryValueDecodeError.self) { try IgbinaryDecoder.decode(value(copies: 30)) }
        #expect(error?.kind == .tooLarge)
    }

    @Test("A copy placed deeper than the array it repeats still fits the depth cap")
    func copiesKeepTheDepthCap() {
        func value(levels: Int) -> Data {
            let chain = 80
            var data = Data([0, 0, 0, 2, 0x15]) + Self.bigEndian(UInt16(levels + 1)) + Data([0x06, 0x00])
            data += Data(Array(repeating: [0x14, 0x01, 0x06, 0x00] as [UInt8], count: chain).joined()) + Data([0x00])
            for level in 1...levels {
                let target = level == 1 ? 1 : chain + level - 1
                data += Data([0x08]) + Self.bigEndian(UInt16(level))
                data += Data([0x14, 0x01, 0x06, 0x00, 0x02]) + Self.bigEndian(UInt16(target))
            }
            return data
        }
        #expect(throws: Never.self) { try IgbinaryDecoder.decode(value(levels: 100)) }
        let error = #expect(throws: BinaryValueDecodeError.self) { try IgbinaryDecoder.decode(value(levels: 200)) }
        #expect(error?.kind == .nestingTooDeep)
    }

    @Test("The version 1 header reads too")
    func versionOne() throws {
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data("000000010607")) == .int(7))
    }

    @Test("A value that is not igbinary names what is wrong and where")
    func brokenValues() {
        let cases: [(hex: String, kind: BinaryValueDecodeError.Kind)] = [
            ("613a313a7b", .unknownVersion(0x613A_313A)),
            ("00000002", .unexpectedEnd),
            ("00000002110568656c", .unexpectedEnd),
            ("00000002ff", .invalidByte(0xFF)),
            ("000000020607aa", .trailingBytes(1)),
            ("00000002140106000e05", .unknownReference(5)),
            ("0000000214010600220a", .unknownReference(10)),
            ("000000021401060001" + "00", .unknownReference(0)),
            ("0000000214011400", .invalidByte(0x14)),
            ("0000000220ffffffffffffffff", .integerOutOfRange),
            ("0000000214ff", .unexpectedEnd),
            ("000000022525" + "00", .invalidByte(0x25)),
        ]
        for testCase in cases {
            let error = #expect(throws: BinaryValueDecodeError.self, "\(testCase.hex)") {
                try IgbinaryDecoder.decode(BinaryFixture.data(testCase.hex))
            }
            #expect(error?.kind == testCase.kind, "\(testCase.hex)")
        }
    }

    @Test("Floats PHP writes with serialize_precision -1, past what the fixtures hold")
    func floatText() {
        #expect(PhpSerializeWriter.floatText(.nan) == "NAN")
        #expect(PhpSerializeWriter.floatText(0.5) == "0.5")
        #expect(PhpSerializeWriter.floatText(-1.5e-7) == "-1.5E-7")
        #expect(PhpSerializeWriter.floatText(1e25) == "1.0E+25")
        #expect(PhpSerializeWriter.floatText(99_999_999_999_999_984) == "99999999999999980")
    }

    private static func latin1(_ hex: String) -> String {
        String(data: BinaryFixture.data(hex), encoding: .isoLatin1) ?? ""
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
