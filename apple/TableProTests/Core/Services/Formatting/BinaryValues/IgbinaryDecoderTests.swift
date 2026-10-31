//
//  IgbinaryDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Fixtures written by the igbinary 3.2.17 extension on PHP 8.3, `igbinary_serialize($value)`, each beside
/// `serialize($value)` of the same value.
struct IgbinaryDecoderTests {
    private static let pointProperties = #"s:1:"x";i:1;s:4:"\#u{0}*\#u{0}y";i:2;s:8:"\#u{0}Point\#u{0}z";i:3;"#

    private static let fixtures: [(name: String, hex: String, serialized: String)] = [
        ("null", "0000000200", "N;"),
        ("true", "0000000205", "b:1;"),
        ("false", "0000000204", "b:0;"),
        ("small int", "000000020607", "i:7;"),
        ("negative int", "0000000209012c", "i:-300;"),
        ("32-bit int", "000000020a00011170", "i:70000;"),
        ("64-bit int", "0000000220000000012a05f200", "i:5000000000;"),
        ("PHP_INT_MAX", "00000002207fffffffffffffff", "i:9223372036854775807;"),
        ("PHP_INT_MIN", "00000002218000000000000000", "i:-9223372036854775808;"),
        ("float", "000000020c400a000000000000", "d:3.25;"),
        ("empty string", "000000020d", #"s:0:"";"#),
        ("UTF-8 string", "00000002110d68c3a96c6c6f2077c3b6726c64", #"s:13:"héllo wörld";"#),
        (
            "list of scalars",
            "000000021406060006010601060206021105746872656506030c4012000000000000060400060504",
            #"a:6:{i:0;i:1;i:1;i:2;i:2;s:5:"three";i:3;d:4.5;i:4;N;i:5;b:0;}"#
        ),
        (
            "nested map with int keys",
            "00000002140511046e616d651103416e6e11047461677314020600110161060111016211046d65746114020e00"
                + "1105696e6e657211016e0701060a110374656e070511036e6567",
            #"a:5:{s:4:"name";s:3:"Ann";s:4:"tags";a:2:{i:0;s:1:"a";i:1;s:1:"b";}s:4:"meta";"#
                + #"a:2:{s:4:"name";s:5:"inner";s:1:"n";i:-1;}i:10;s:3:"ten";i:-5;s:3:"neg";}"#
        ),
        (
            "repeated strings by ID",
            "00000002140506001105616c706861060111046265746106020e0006030e0106040e00",
            #"a:5:{i:0;s:5:"alpha";i:1;s:4:"beta";i:2;s:5:"alpha";i:3;s:4:"beta";i:4;s:5:"alpha";}"#
        ),
        (
            "object with every visibility",
            "000000021705506f696e74140311017806011104002a00790602110800506f696e74007a0603",
            #"O:5:"Point":3:{"# + pointProperties + "}"
        ),
        (
            "stdClass",
            "000000021708737464436c617373140211016106011101621401060005",
            #"O:8:"stdClass":2:{s:1:"a";i:1;s:1:"b";a:1:{i:0;b:1;}}"#
        ),
        ("enum case", "00000002170453756974271106486561727473", #"E:11:"Suit:Hearts";"#),
    ]

    @Test("Each fixture decodes to the value PHP's serialize() wrote, and writes it back the same")
    func fixturesMatchSerialize() throws {
        for fixture in Self.fixtures {
            let decoded = try IgbinaryDecoder.decode(BinaryFixture.data(fixture.hex))
            #expect(decoded == PhpSerializeParser.parse(fixture.serialized), "\(fixture.name)")
            #expect(PhpSerializeWriter.text(decoded) == fixture.serialized, "\(fixture.name)")
        }
    }

    @Test("A string of 300 bytes uses the 16-bit length")
    func longString() throws {
        let hex = "0000000212012c" + String(repeating: "61", count: 300)
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data(hex)) == .string(String(repeating: "a", count: 300)))
    }

    @Test("A repeated object refers back with the number serialize() gives it")
    func repeatedObject() throws {
        let hex = "00000002140306001705506f696e74140311017806011104002a00790602110800506f696e74007a0603"
            + "0601220106021a0014030e0106010e0206020e030603"
        let point = #"O:5:"Point":3:{"# + Self.pointProperties + "}"
        let serialized = "a:3:{i:0;\(point)i:1;r:2;i:2;\(point)}"
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data(hex)) == PhpSerializeParser.parse(serialized))
    }

    @Test("A repeated enum case refers back to the first one")
    func repeatedEnumCase() throws {
        let hex = "000000021403060017045375697427110648656172747306011a0027110653706164657306022201"
        let serialized = #"a:3:{i:0;E:11:"Suit:Hearts";i:1;E:11:"Suit:Spades";i:2;r:2;}"#
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data(hex)) == PhpSerializeParser.parse(serialized))
    }

    @Test("A PHP reference counts once, as R: numbers it")
    func phpReference() throws {
        let hex = "0000000214020600251401060011067368617265640601250101"
        let serialized = #"a:2:{i:0;a:1:{i:0;s:6:"shared";}i:1;R:2;}"#
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data(hex)) == PhpSerializeParser.parse(serialized))
        #expect(PhpSerializeWriter.text(try IgbinaryDecoder.decode(BinaryFixture.data(hex))) == serialized)
    }

    @Test("An array repeated by value is written out again, as serialize() writes it, and later numbers follow")
    func arraysByValue() throws {
        let cases: [(hex: String, serialized: String)] = [
            (
                "0000000214020600140206000601060111017806010101",
                #"a:2:{i:0;a:2:{i:0;i:1;i:1;s:1:"x";}i:1;a:2:{i:0;i:1;i:1;s:1:"x";}}"#
            ),
            (
                "0000000214030600140206001705506f696e7414011101780601060106020601010106022202",
                #"a:3:{i:0;a:2:{i:0;O:5:"Point":1:{s:1:"x";i:1;}i:1;i:2;}i:1;a:2:{i:0;r:3;i:1;i:2;}i:2;r:3;}"#
            ),
            (
                "0000000214030600140111016b140206000601060106020601010206020101",
                #"a:3:{i:0;a:1:{s:1:"k";a:2:{i:0;i:1;i:1;i:2;}}i:1;a:2:{i:0;i:1;i:1;i:2;}i:2;a:1:{s:1:"k";a:2:{i:0;i:1;i:1;i:2;}}}"#
            ),
            (
                "000000021404060014030600060106010602060206030601010106021705506f696e741401110178060106032202",
                #"a:4:{i:0;a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}i:1;a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}i:2;O:5:"Point":1:{s:1:"x";i:1;}i:3;r:10;}"#
            ),
            ("000000021708737464436c6173731401110473656c662200", #"O:8:"stdClass":1:{s:4:"self";r:1;}"#),
            ("00000002140306002506050601250101060211017a", #"a:3:{i:0;i:5;i:1;R:2;i:2;s:1:"z";}"#),
        ]
        for testCase in cases {
            #expect(try IgbinaryDecoder.decode(BinaryFixture.data(testCase.hex)) == PhpSerializeParser.parse(testCase.serialized))
        }
    }

    @Test("Arrays nested by value forty deep are refused rather than expanded")
    func exponentialCopiesAreRefused() {
        func level(_ depth: Int, of total: Int) -> String {
            guard depth > 0 else { return "140206000601060106010601" }
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
            ("0000000214011400", .invalidByte(0x14)),
            ("0000000220ffffffffffffffff", .integerOutOfRange),
            ("0000000214ff", .unexpectedEnd),
        ]
        for testCase in cases {
            let error = #expect(throws: BinaryValueDecodeError.self, "\(testCase.hex)") {
                try IgbinaryDecoder.decode(BinaryFixture.data(testCase.hex))
            }
            #expect(error?.kind == testCase.kind, "\(testCase.hex)")
        }
    }

    @Test("Floats follow serialize_precision -1")
    func floatText() {
        #expect(PhpSerializeWriter.floatText(1) == "1")
        #expect(PhpSerializeWriter.floatText(0.1) == "0.1")
        #expect(PhpSerializeWriter.floatText(1e25) == "1.0E+25")
        #expect(PhpSerializeWriter.floatText(1.5e-7) == "1.5E-7")
        #expect(PhpSerializeWriter.floatText(-.infinity) == "-INF")
    }
}
