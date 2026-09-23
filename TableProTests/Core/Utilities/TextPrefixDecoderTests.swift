//
//  TextPrefixDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Text prefix decoder")
struct TextPrefixDecoderTests {
    private static let prefixLength = 64

    private func straddlingBytes(_ character: String, bytesInsidePrefix: Int) -> Data {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: Self.prefixLength - bytesInsidePrefix)
        bytes.append(Data(character.utf8))
        bytes.append(Data("tail".utf8))
        return bytes
    }

    @Test(
        "A character the prefix cuts in half is completed, not read as Latin-1",
        arguments: ["\u{E1}", "\u{1EC7}", "\u{1F600}"]
    )
    func completesACutCharacter(character: String) throws {
        let characterLength = Data(character.utf8).count
        for bytesInsidePrefix in 1..<characterLength {
            let bytes = straddlingBytes(character, bytesInsidePrefix: bytesInsidePrefix)
            #expect(String(data: bytes.prefix(Self.prefixLength), encoding: .utf8) == nil)

            let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: Self.prefixLength))

            #expect(decoded.encoding == .utf8)
            #expect(decoded.content.hasSuffix("a" + character))
        }
    }

    @Test("A prefix that ends on a character boundary reads exactly the prefix")
    func readsExactlyThePrefixOnABoundary() throws {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: Self.prefixLength)
        bytes.append(Data("\u{E1}bc".utf8))

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: Self.prefixLength))

        #expect(decoded.encoding == .utf8)
        #expect(decoded.content == String(repeating: "a", count: Self.prefixLength))
    }

    @Test("Genuinely Latin-1 text is still read as Latin-1")
    func readsLatin1AsLatin1() throws {
        let bytes = try #require("-- @name: Caf\u{E9} cr\u{E8}me\n".data(using: .isoLatin1))

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))

        #expect(decoded.encoding == .isoLatin1)
        #expect(decoded.content == "-- @name: Caf\u{E9} cr\u{E8}me\n")
    }

    @Test("A Latin-1 byte that looks like a cut character at the limit stays Latin-1")
    func keepsALatin1LeadByteAtTheLimitAsLatin1() throws {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: Self.prefixLength - 1)
        bytes.append(0xE9)
        bytes.append(Data("xyz".utf8))

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: Self.prefixLength))

        #expect(decoded.encoding == .isoLatin1)
        #expect(decoded.content == String(repeating: "a", count: Self.prefixLength - 1) + "\u{E9}")
    }

    @Test("Text that ends partway through a character is not UTF-8")
    func treatsATruncatedFileAsLatin1() throws {
        var bytes = Data("abc".utf8)
        bytes.append(0xC3)

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))

        #expect(decoded.encoding == .isoLatin1)
    }

    @Test("A short UTF-8 text is read whole")
    func readsShortTextWhole() throws {
        let bytes = Data("-- @name: B\u{E1}o c\u{E1}o\n".utf8)

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))

        #expect(decoded.encoding == .utf8)
        #expect(decoded.content == "-- @name: B\u{E1}o c\u{E1}o\n")
    }

    @Test("A UTF-8 byte order mark is dropped from the text")
    func dropsTheUTF8ByteOrderMark() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("-- @name: B\u{E1}o\n".utf8)

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))

        #expect(decoded.encoding == .utf8)
        #expect(decoded.content == "-- @name: B\u{E1}o\n")
    }

    @Test("UTF-16 with a little-endian byte order mark is read as UTF-16")
    func readsLittleEndianUTF16() throws {
        let text = try #require("-- @name: B\u{E1}o c\u{E1}o\n".data(using: .utf16LittleEndian))

        let decoded = try #require(TextPrefixDecoder.decode(Data([0xFF, 0xFE]) + text, prefixLength: 4_096))

        #expect(decoded.encoding == .utf16)
        #expect(decoded.content == "-- @name: B\u{E1}o c\u{E1}o\n")
    }

    @Test("UTF-16 with a big-endian byte order mark is read as UTF-16")
    func readsBigEndianUTF16() throws {
        let text = try #require("-- @name: B\u{E1}o c\u{E1}o\n".data(using: .utf16BigEndian))

        let decoded = try #require(TextPrefixDecoder.decode(Data([0xFE, 0xFF]) + text, prefixLength: 4_096))

        #expect(decoded.encoding == .utf16)
        #expect(decoded.content == "-- @name: B\u{E1}o c\u{E1}o\n")
    }

    @Test("A UTF-16 surrogate pair the prefix cuts in half is completed")
    func completesACutSurrogatePair() throws {
        let text = try #require("ab\u{1F600}cd".data(using: .utf16LittleEndian))
        let bytes = Data([0xFF, 0xFE]) + text

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 8))

        #expect(decoded.encoding == .utf16)
        #expect(decoded.content == "ab\u{1F600}")
    }

    @Test("UTF-32 with a byte order mark is read as UTF-32")
    func readsUTF32() throws {
        let text = try #require("-- @name: B\u{E1}o\n".data(using: .utf32LittleEndian))
        let bytes = Data([0xFF, 0xFE, 0x00, 0x00]) + text

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))

        #expect(decoded.encoding == .utf32)
        #expect(decoded.content == "-- @name: B\u{E1}o\n")
    }

    @Test("UTF-32 with a big-endian byte order mark is read as UTF-32")
    func readsBigEndianUTF32() throws {
        let text = try #require("-- @name: B\u{E1}o\n".data(using: .utf32BigEndian))
        let bytes = Data([0x00, 0x00, 0xFE, 0xFF]) + text

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))

        #expect(decoded.encoding == .utf32)
        #expect(decoded.content == "-- @name: B\u{E1}o\n")
    }

    @Test("A prefix that ends partway through a UTF-32 code unit is completed, not shortened")
    func completesACutUTF32CodeUnit() throws {
        let text = try #require("abc".data(using: .utf32LittleEndian))
        let bytes = Data([0xFF, 0xFE, 0x00, 0x00]) + text

        let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 9))

        #expect(decoded.encoding == .utf32)
        #expect(decoded.content == "ab")
    }

    @Test("Text whose last code unit is cut off is not in the encoding its mark names")
    func treatsACutMarkedTextAsLatin1() throws {
        let utf16 = try Data([0xFF, 0xFE]) + #require("ab".data(using: .utf16LittleEndian)) + Data([0x41])
        let utf32 = try Data([0x00, 0x00, 0xFE, 0xFF]) + #require("ab".data(using: .utf32BigEndian)).dropLast(1)

        for bytes in [utf16, utf32] {
            let decoded = try #require(TextPrefixDecoder.decode(bytes, prefixLength: 4_096))
            #expect(decoded.encoding == .isoLatin1)
            #expect(decoded.content == String(data: bytes, encoding: .isoLatin1))
        }
    }

    @Test("No bytes is no text")
    func returnsNothingForNoBytes() {
        #expect(TextPrefixDecoder.decode(Data(), prefixLength: 4_096) == nil)
    }
}
