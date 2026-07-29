//
//  PhpSerializeParserTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("PhpSerializeParser - scalar tokens")
struct PhpSerializeParserScalarTests {
    @Test("null token parses to .null")
    func nullToken() {
        #expect(PhpSerializeParser.parse("N;") == .null)
    }

    @Test("boolean true parses to .bool(true)")
    func boolTrue() {
        #expect(PhpSerializeParser.parse("b:1;") == .bool(true))
    }

    @Test("boolean false parses to .bool(false)")
    func boolFalse() {
        #expect(PhpSerializeParser.parse("b:0;") == .bool(false))
    }

    @Test("integer parses to .int")
    func integer() {
        #expect(PhpSerializeParser.parse("i:42;") == .int(42))
    }

    @Test("negative integer parses to .int")
    func negativeInteger() {
        #expect(PhpSerializeParser.parse("i:-7;") == .int(-7))
    }

    @Test("float parses to .float")
    func float() {
        #expect(PhpSerializeParser.parse("d:3.14;") == .float(3.14))
    }

    @Test("INF parses to positive infinity")
    func floatInfinity() {
        guard case let .float(value)? = PhpSerializeParser.parse("d:INF;") else {
            Issue.record("expected float")
            return
        }
        #expect(value.isInfinite && value > 0)
    }

    @Test("-INF parses to negative infinity")
    func floatNegativeInfinity() {
        guard case let .float(value)? = PhpSerializeParser.parse("d:-INF;") else {
            Issue.record("expected float")
            return
        }
        #expect(value.isInfinite && value < 0)
    }

    @Test("NAN parses to .nan")
    func floatNan() {
        guard case let .float(value)? = PhpSerializeParser.parse("d:NAN;") else {
            Issue.record("expected float")
            return
        }
        #expect(value.isNaN)
    }
}

@Suite("PhpSerializeParser - strings")
struct PhpSerializeParserStringTests {
    @Test("ASCII string parses")
    func asciiString() {
        #expect(PhpSerializeParser.parse("s:5:\"hello\";") == .string("hello"))
    }

    @Test("empty string parses")
    func emptyString() {
        #expect(PhpSerializeParser.parse("s:0:\"\";") == .string(""))
    }

    @Test("S token parses identically to s")
    func capitalS() {
        #expect(PhpSerializeParser.parse("S:5:\"hello\";") == .string("hello"))
    }

    @Test("multi-byte UTF-8 string respects byte length")
    func multiByteString() {
        let utf8Bytes = Array("héllo".utf8)
        let serialized = "s:\(utf8Bytes.count):\"héllo\";"
        #expect(PhpSerializeParser.parse(serialized) == .string("héllo"))
    }

    @Test("declared length mismatch returns nil")
    func lengthMismatch() {
        #expect(PhpSerializeParser.parse("s:10:\"hi\";") == nil)
    }

    @Test("string containing quotes parses")
    func stringWithQuotes() {
        let raw = "say \"hi\""
        let bytes = Array(raw.utf8)
        let serialized = "s:\(bytes.count):\"\(raw)\";"
        #expect(PhpSerializeParser.parse(serialized) == .string(raw))
    }
}

@Suite("PhpSerializeParser - arrays")
struct PhpSerializeParserArrayTests {
    @Test("empty array parses")
    func emptyArray() {
        #expect(PhpSerializeParser.parse("a:0:{}") == .array([]))
    }

    @Test("integer-keyed array parses")
    func intKeyedArray() {
        let result = PhpSerializeParser.parse("a:2:{i:0;s:1:\"a\";i:1;s:1:\"b\";}")
        guard case let .array(entries)? = result else {
            Issue.record("expected array")
            return
        }
        #expect(entries.count == 2)
        #expect(entries[0].key == .int(0))
        #expect(entries[0].value == .string("a"))
        #expect(entries[1].key == .int(1))
        #expect(entries[1].value == .string("b"))
    }

    @Test("string-keyed array preserves source order")
    func stringKeyedArrayOrder() {
        let result = PhpSerializeParser.parse(
            "a:3:{s:1:\"z\";i:1;s:1:\"a\";i:2;s:1:\"m\";i:3;}"
        )
        guard case let .array(entries)? = result else {
            Issue.record("expected array")
            return
        }
        #expect(entries.count == 3)
        #expect(entries[0].key == .string("z"))
        #expect(entries[1].key == .string("a"))
        #expect(entries[2].key == .string("m"))
    }

    @Test("nested array parses")
    func nestedArray() {
        let result = PhpSerializeParser.parse("a:1:{i:0;a:1:{i:0;i:42;}}")
        guard case let .array(outer)? = result,
              outer.count == 1,
              case let .array(inner) = outer[0].value,
              inner.count == 1,
              case .int(42) = inner[0].value else {
            Issue.record("expected nested array structure")
            return
        }
    }
}

@Suite("PhpSerializeParser - objects")
struct PhpSerializeParserObjectTests {
    @Test("object with public property")
    func publicProperty() {
        let result = PhpSerializeParser.parse("O:4:\"User\":1:{s:4:\"name\";s:3:\"Bob\";}")
        guard case let .object(className, properties)? = result else {
            Issue.record("expected object")
            return
        }
        #expect(className == "User")
        #expect(properties.count == 1)
        #expect(properties[0].name == "name")
        #expect(properties[0].visibility == .publicVisibility)
        #expect(properties[0].value == .string("Bob"))
    }

    @Test("protected property decodes mangling")
    func protectedProperty() {
        let nullByte = "\u{0000}"
        let mangled = "\(nullByte)*\(nullByte)secret"
        let mangledBytes = Array(mangled.utf8)
        let serialized = "O:4:\"User\":1:{s:\(mangledBytes.count):\"\(mangled)\";s:5:\"value\";}"
        let result = PhpSerializeParser.parse(serialized)
        guard case let .object(_, properties)? = result, properties.count == 1 else {
            Issue.record("expected one property")
            return
        }
        #expect(properties[0].name == "secret")
        #expect(properties[0].visibility == .protectedVisibility)
    }

    @Test("private property decodes mangling with class name")
    func privateProperty() {
        let nullByte = "\u{0000}"
        let mangled = "\(nullByte)User\(nullByte)secret"
        let mangledBytes = Array(mangled.utf8)
        let serialized = "O:4:\"User\":1:{s:\(mangledBytes.count):\"\(mangled)\";s:5:\"value\";}"
        let result = PhpSerializeParser.parse(serialized)
        guard case let .object(_, properties)? = result, properties.count == 1 else {
            Issue.record("expected one property")
            return
        }
        #expect(properties[0].name == "secret")
        #expect(properties[0].visibility == .privateVisibility(className: "User"))
    }
}

@Suite("PhpSerializeParser - special tokens")
struct PhpSerializeParserSpecialTests {
    @Test("C token returns .serializable with class + payload")
    func serializableToken() {
        let result = PhpSerializeParser.parse("C:3:\"Foo\":5:{xyzab}")
        guard case let .serializable(className, payload)? = result else {
            Issue.record("expected serializable")
            return
        }
        #expect(className == "Foo")
        #expect(payload == "xyzab")
    }

    @Test("r token returns .reference")
    func referenceLowerR() {
        #expect(PhpSerializeParser.parse("r:7;") == .reference(id: 7))
    }

    @Test("R token returns .reference")
    func referenceUpperR() {
        #expect(PhpSerializeParser.parse("R:42;") == .reference(id: 42))
    }

    @Test("o (PHP-3) token returns .unsupported")
    func oToken() {
        guard case let .unsupported(token)? = PhpSerializeParser.parse("o:0:\"X\":0:{}") else {
            Issue.record("expected unsupported")
            return
        }
        #expect(token == "o")
    }

    @Test("truncated input returns nil")
    func truncatedInput() {
        #expect(PhpSerializeParser.parse("s:5:\"he") == nil)
    }

    @Test("malformed token returns nil")
    func malformedInput() {
        #expect(PhpSerializeParser.parse("x:1;") == nil)
    }

    @Test("empty string returns nil")
    func emptyInput() {
        #expect(PhpSerializeParser.parse("") == nil)
    }
}

@Suite("PhpSerializeParser - depth cap")
struct PhpSerializeParserDepthTests {
    @Test("looksLikePhpSerialized accepts valid PHP-like prefix")
    func looksLikePositive() {
        #expect(PhpSerializeParser.looksLikePhpSerialized("N;"))
        #expect(PhpSerializeParser.looksLikePhpSerialized("a:0:{}"))
        #expect(PhpSerializeParser.looksLikePhpSerialized("s:5:\"hello\";"))
    }

    @Test("looksLikePhpSerialized rejects unrelated content")
    func looksLikeNegative() {
        #expect(!PhpSerializeParser.looksLikePhpSerialized(""))
        #expect(!PhpSerializeParser.looksLikePhpSerialized("hello world"))
        #expect(!PhpSerializeParser.looksLikePhpSerialized("{\"a\":1}"))
    }

    @Test("looksLikePhpSerialized rejects unlikely first-char text")
    func looksLikeRejectsAmbiguous() {
        #expect(!PhpSerializeParser.looksLikePhpSerialized("a quick brown fox"))
        #expect(!PhpSerializeParser.looksLikePhpSerialized("some text"))
    }
}
