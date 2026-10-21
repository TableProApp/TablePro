//
//  IgbinaryDecoderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Fixtures written by `igbinary_serialize` (igbinary 3.2.17RC1, PHP 8.3.35). Each expectation is what
/// `serialize()` printed for the same value in the same run.
struct IgbinaryDecoderTests {
    private static func serialized(_ hex: String) throws -> String {
        PhpSerializeWriter.serialize(try IgbinaryDecoder.decode(BinaryFixture.data(hex)))
    }

    @Test("Scalars, nested arrays, integer keys and the int64 limits")
    func scalars() throws {
        let hex = "00000002140e1103666f6f060111036261721403060006010601060206020603110362617a11037175781101660c3ff8"
            + "0000000000001101740511016e0011036e656709012c1103626967207fffffffffffffff11036d696e2180000000000000"
            + "001105656d7074790d1104757466381105636166c3a911066e657374656414011101611401110162140006071105736576"
            + "656e070111056d696e7573"
        let expected = #"a:14:{s:3:"foo";i:1;s:3:"bar";a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}s:3:"baz";s:3:"qux";"#
            + #"s:1:"f";d:1.5;s:1:"t";b:1;s:1:"n";N;s:3:"neg";i:-300;s:3:"big";i:9223372036854775807;"#
            + #"s:3:"min";i:-9223372036854775808;s:5:"empty";s:0:"";s:4:"utf8";s:5:"café";"#
            + #"s:6:"nested";a:1:{s:1:"a";a:1:{s:1:"b";a:0:{}}}i:7;s:5:"seven";i:-1;s:5:"minus";}"#
        #expect(try Self.serialized(hex) == expected)
    }

    @Test("An object keeps protected and private property names")
    func object() throws {
        let hex = "00000002170455736572140311046e616d651103416e6e1106002a00616765061e110c005573657200736563726574110178"
        let expected = "O:4:\"User\":3:{s:4:\"name\";s:3:\"Ann\";s:6:\"\u{0}*\u{0}age\";i:30;"
            + "s:12:\"\u{0}User\u{0}secret\";s:1:\"x\";}"
        #expect(try Self.serialized(hex) == expected)
        let value = try IgbinaryDecoder.decode(BinaryFixture.data(hex))
        guard case .object(_, let properties) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(properties.map { $0.visibility } == [
            .publicVisibility, .protectedVisibility, .privateVisibility(className: "User"),
        ])
    }

    @Test("A repeated string is read back from the string table")
    func stringTable() throws {
        let expected = #"a:4:{s:1:"a";s:4:"same";s:1:"b";s:4:"same";s:4:"same";i:1;s:1:"c";a:1:{s:4:"same";s:4:"same";}}"#
        #expect(try Self.serialized("000000021404110161110473616d651101620e010e01060111016314010e010e01") == expected)
    }

    @Test("Enum cases, and a repeated one as a reference numbered as serialize() numbers it")
    func enumCases() throws {
        let hex = "000000021403060017045375697427110648656172747306011a0027110653706164657306022201"
        #expect(try Self.serialized(hex) == #"a:3:{i:0;E:11:"Suit:Hearts";i:1;E:11:"Suit:Spades";i:2;r:2;}"#)
    }

    @Test("An object seen twice is a reference to the first")
    func objectReference() throws {
        let hex = "00000002140206001708737464436c617373140111026964060706012201"
        #expect(try Self.serialized(hex) == #"a:2:{i:0;O:8:"stdClass":1:{s:2:"id";i:7;}i:1;r:2;}"#)
    }

    @Test(
        "A PHP reference to a scalar or an array is R:, numbered as serialize() numbers it",
        arguments: [
            ("000000021402060025062a0601250101", "a:2:{i:0;i:42;i:1;R:2;}"),
            ("000000021403060025140106000601060125010111016b0605", #"a:3:{i:0;a:1:{i:0;i:1;}i:1;R:2;s:1:"k";i:5;}"#),
        ]
    )
    func variableReferences(hex: String, expected: String) throws {
        #expect(try Self.serialized(hex) == expected)
    }

    @Test("A string that is not UTF-8 stays bytes, with its true length")
    func binaryString() throws {
        #expect(try IgbinaryDecoder.decode(BinaryFixture.data("000000021101ff")) == .bytes(Data([0xFF])))
        #expect(try Self.serialized("000000021101ff") == #"s:1:"\xFF";"#)
        #expect(try Self.serialized("0000000211035cff41") == #"s:3:"\\\xFFA";"#)
        let tree = PhpTreeBuilder.build(from: .bytes(Data([0xFF])), formats: BinaryFixture.english)
        #expect(tree.badgeLabel == "bin")
        #expect(tree.copyableValue == #"\xFF"#)
    }

    @Test("A Serializable object keeps its payload")
    func serializable() throws {
        #expect(try Self.serialized("000000021705506f696e741d03312c32") == #"C:5:"Point":3:{1,2}"#)
    }

    @Test("Top-level scalars")
    func topLevelScalars() throws {
        #expect(try Self.serialized("00000002062a") == "i:42;")
        #expect(try Self.serialized("00000002110568656c6c6f") == #"s:5:"hello";"#)
        #expect(try Self.serialized("000000020c3fb999999999999a") == "d:0.1;")
    }

    @Test("A value without the version header is refused")
    func wrongHeader() {
        #expect(throws: BinaryValueDecodeError(kind: .unsupportedVersion(3), offset: 0)) {
            try IgbinaryDecoder.decode(BinaryFixture.data("00000003062a"))
        }
        #expect(throws: BinaryValueDecodeError(kind: .unexpectedEnd, offset: 4)) {
            try IgbinaryDecoder.decode(BinaryFixture.data("00000002"))
        }
    }

    @Test("A string id past the table is refused")
    func unknownStringID() {
        #expect(throws: BinaryValueDecodeError(kind: .unknownReference(3), offset: 5)) {
            try IgbinaryDecoder.decode(BinaryFixture.data("000000020e03"))
        }
    }

    @Test("A value cut short is refused")
    func truncated() {
        #expect(throws: BinaryValueDecodeError(kind: .unexpectedEnd, offset: 9)) {
            try IgbinaryDecoder.decode(BinaryFixture.data("00000002110568656c"))
        }
    }

    @Test("The tree is the PHP serialized viewer's tree")
    func tree() throws {
        let value = try IgbinaryDecoder.decode(BinaryFixture.data("000000021705506f696e741d03312c32"))
        let tree = PhpTreeBuilder.build(from: value, formats: BinaryFixture.english)
        #expect(tree.badgeLabel == "ser")
        #expect(tree.className == "Point")
    }
}

struct PhpSerializeWriterTests {
    @Test(
        "Floats are spelled the way serialize() spells them",
        arguments: [
            (1.0, "1"), (0.1, "0.1"), (1e100, "1.0E+100"), (1.5e-7, "1.5E-7"), (-0.0, "-0"),
            (1.2345678901234568e17, "1.2345678901234568E+17"), (1e14, "100000000000000"), (0.0001, "0.0001"),
            (1e-5, "1.0E-5"), (5e-324, "5.0E-324"), (Double.nan, "NAN"), (Double.infinity, "INF"),
            (-Double.infinity, "-INF"),
        ]
    )
    func floats(value: Double, expected: String) {
        #expect(PhpSerializeWriter.floatText(value) == expected)
    }

    @Test("What the writer produces, the parser reads back")
    func roundTrip() {
        let value = PhpValue.array([
            PhpKeyValue(key: .string("suit"), value: .enumCase(className: "App\\Suit", caseName: "Hearts")),
            PhpKeyValue(key: .int(1), value: .object(className: "User", properties: [
                PhpProperty(name: "secret", visibility: .privateVisibility(className: "User"), value: .string("x")),
            ])),
        ])
        #expect(PhpSerializeParser.parse(PhpSerializeWriter.serialize(value)) == value)
    }
}
