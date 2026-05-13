//
//  LibPQByteaDecoderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("LibPQByteaDecoder - hex format")
struct LibPQByteaDecoderHexTests {
    @Test("Empty input returns empty Data")
    func emptyInput() {
        #expect(LibPQByteaDecoder.decode("") == Data())
    }

    @Test("Empty hex (\\x with no digits) returns empty Data")
    func emptyHexPrefix() {
        #expect(LibPQByteaDecoder.decode("\\x") == Data())
    }

    @Test("Single byte 0x00 round-trips")
    func singleByteZero() {
        #expect(LibPQByteaDecoder.decode("\\x00") == Data([0x00]))
    }

    @Test("Single byte 0xFF round-trips")
    func singleByteHigh() {
        #expect(LibPQByteaDecoder.decode("\\xff") == Data([0xFF]))
    }

    @Test("Lowercase hex parses correctly")
    func lowercaseHex() {
        #expect(LibPQByteaDecoder.decode("\\xdeadbeef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Uppercase hex parses correctly")
    func uppercaseHex() {
        #expect(LibPQByteaDecoder.decode("\\xDEADBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Mixed-case hex parses correctly")
    func mixedCaseHex() {
        #expect(LibPQByteaDecoder.decode("\\xDeAdBeEf") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Uppercase \\X prefix accepted")
    func uppercaseXPrefix() {
        #expect(LibPQByteaDecoder.decode("\\X48656c6c6f") == Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]))
    }

    @Test("Odd hex length returns nil")
    func oddHexLength() {
        #expect(LibPQByteaDecoder.decode("\\xabc") == nil)
    }

    @Test("Non-hex character returns nil")
    func nonHexCharacter() {
        #expect(LibPQByteaDecoder.decode("\\xdeadXX") == nil)
    }

    @Test("Embedded NUL byte 0x00 mid-stream round-trips")
    func embeddedNullByte() {
        // "Hello\0World" → 11 bytes including the embedded NUL
        let expected = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64])
        #expect(LibPQByteaDecoder.decode("\\x48656c6c6f00576f726c64") == expected)
    }

    @Test("All 256 byte values 0x00-0xFF decode losslessly")
    func allByteValues() {
        let hex = (0..<256).map { String(format: "%02x", $0) }.joined()
        let result = LibPQByteaDecoder.decode("\\x" + hex)
        #expect(result?.count == 256)
        #expect(result == Data((0..<256).map { UInt8($0) }))
    }
}

@Suite("LibPQByteaDecoder - escape format")
struct LibPQByteaDecoderEscapeTests {
    @Test("Plain ASCII bytes pass through")
    func plainAscii() {
        #expect(LibPQByteaDecoder.decode("Hello, World!") == Data("Hello, World!".utf8))
    }

    @Test("Escaped backslash decodes to 0x5C")
    func escapedBackslash() {
        #expect(LibPQByteaDecoder.decode("\\\\") == Data([0x5C]))
    }

    @Test("Escaped backslash mixed with ASCII")
    func escapedBackslashMixed() {
        #expect(LibPQByteaDecoder.decode("a\\\\b") == Data([0x61, 0x5C, 0x62]))
    }

    @Test("Octal escape \\012 decodes to 0x0A (newline)")
    func octalEscapeNewline() {
        #expect(LibPQByteaDecoder.decode("\\012") == Data([0x0A]))
    }

    @Test("Octal escape \\377 decodes to 0xFF (max valid)")
    func octalEscapeMax() {
        #expect(LibPQByteaDecoder.decode("\\377") == Data([0xFF]))
    }

    @Test("Octal escape \\000 decodes to 0x00")
    func octalEscapeZero() {
        #expect(LibPQByteaDecoder.decode("\\000") == Data([0x00]))
    }

    @Test("Bare backslash with insufficient digits returns nil")
    func badEscapeShort() {
        #expect(LibPQByteaDecoder.decode("\\1") == nil)
    }

    @Test("Backslash followed by non-octal returns nil")
    func badEscapeNonOctal() {
        #expect(LibPQByteaDecoder.decode("\\xyz") == nil)
    }

    @Test("Bare trailing backslash returns nil")
    func trailingBackslash() {
        #expect(LibPQByteaDecoder.decode("abc\\") == nil)
    }
}

@Suite("LibPQByteaDecoder - issue #1188 regression")
struct LibPQByteaDecoderIssue1188Tests {
    @Test("Issue #1188 exact value decodes to 48 bytes")
    func issue1188ExactValue() {
        let input = "\\xd38ce566b967520caf461747abc77d275f084f601697d1ea135b0361cabb534f702202b952e00447b675687af8f5d43b"
        let expected = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let result = LibPQByteaDecoder.decode(input)
        #expect(result?.count == 48)
        #expect(result == expected)
    }

    @Test("Issue #1188 first byte is 0xD3 (not ASCII '\\\\')")
    func issue1188FirstByteIsBinary() {
        let input = "\\xd38ce566"
        guard let result = LibPQByteaDecoder.decode(input) else {
            Issue.record("Decoder returned nil for valid input")
            return
        }
        #expect(result.first == 0xD3)
        #expect(result.first != 0x5C)
    }
}

@Suite("LibPQByteaDecoder - hex round-trip")
struct LibPQByteaDecoderEncodeTests {
    @Test("encodeHexText produces canonical \\xHH format")
    func canonicalHexEncoding() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(LibPQByteaDecoder.encodeHexText(data) == "\\xdeadbeef")
    }

    @Test("Empty Data encodes to bare \\x")
    func emptyDataEncoding() {
        #expect(LibPQByteaDecoder.encodeHexText(Data()) == "\\x")
    }

    @Test("Round-trip preserves bytes exactly")
    func roundTrip() {
        let original = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 13) })
        let encoded = LibPQByteaDecoder.encodeHexText(original)
        #expect(LibPQByteaDecoder.decode(encoded) == original)
    }

    @Test("Round-trip across all 256 byte values")
    func roundTripAllBytes() {
        let original = Data((0..<256).map { UInt8($0) })
        let encoded = LibPQByteaDecoder.encodeHexText(original)
        #expect(LibPQByteaDecoder.decode(encoded) == original)
    }
}
