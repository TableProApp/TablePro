//
//  BinaryTextDecoderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("BinaryTextDecoder")
struct BinaryTextDecoderTests {
    @Test("ASCII bytes decode to their text")
    func asciiDecodes() {
        #expect(BinaryTextDecoder.decode(Data("hello world".utf8)) == "hello world")
    }

    @Test("Multi-byte UTF-8 survives")
    func multiByteDecodes() {
        #expect(BinaryTextDecoder.decode(Data("café 日本語 🎉".utf8)) == "café 日本語 🎉")
    }

    @Test("Tabs and line breaks stay readable")
    func whitespaceIsText() {
        #expect(BinaryTextDecoder.decode(Data("a\tb\nc\r\nd".utf8)) == "a\tb\nc\r\nd")
    }

    @Test("Bytes that are not UTF-8 decode to nothing")
    func invalidUtf8Rejected() {
        #expect(BinaryTextDecoder.decode(Data([0xFF, 0xFE, 0xFD])) == nil)
    }

    @Test("A PNG header decodes to nothing")
    func pngRejected() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(BinaryTextDecoder.decode(png) == nil)
    }

    @Test("A gzip header decodes to nothing")
    func gzipRejected() {
        #expect(BinaryTextDecoder.decode(Data([0x1F, 0x8B, 0x08, 0x00])) == nil)
    }

    @Test("Sixteen UUID bytes decode to nothing")
    func uuidBytesRejected() {
        let uuid = Data([
            0x55, 0x0E, 0x84, 0x00, 0xE2, 0x9B, 0x41, 0xD4,
            0xA7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
        ])
        #expect(BinaryTextDecoder.decode(uuid) == nil)
    }

    @Test("A packed IPv4 address decodes to nothing")
    func packedAddressRejected() {
        #expect(BinaryTextDecoder.decode(Data([0xC0, 0xA8, 0x01, 0x01])) == nil)
    }

    @Test("DEL is not text")
    func deleteCharacterRejected() {
        #expect(BinaryTextDecoder.decode(Data([0x61, 0x7F, 0x62])) == nil)
    }

    @Test("BINARY padding is trimmed off the end")
    func trailingPaddingTrimmed() {
        var padded = Data("hello".utf8)
        padded.append(Data(repeating: 0, count: 27))
        #expect(BinaryTextDecoder.decode(padded, columnType: .blob(rawType: "BINARY(32)")) == "hello")
    }

    @Test("only a fixed-width BINARY column pads, so no other type gives up a trailing NUL")
    func trailingNulIsDataOutsideFixedWidthBinary() {
        let value = Data([0x61, 0x00])

        #expect(BinaryTextDecoder.decode(value, columnType: .blob(rawType: "BINARY(2)")) == "a")
        #expect(BinaryTextDecoder.decode(value, columnType: .blob(rawType: "VARBINARY(255)")) == nil)
        #expect(BinaryTextDecoder.decode(value, columnType: .blob(rawType: "BLOB")) == nil)
        #expect(BinaryTextDecoder.decode(value, columnType: .blob(rawType: "bytea")) == nil)
        #expect(BinaryTextDecoder.decode(value) == nil)
    }

    @Test("padding is trimmed for BINARY with or without a declared width")
    func paddingPolicyReadsTheBaseTypeName() {
        #expect(BinaryTextDecoder.padsToFixedWidth(.blob(rawType: "BINARY")))
        #expect(BinaryTextDecoder.padsToFixedWidth(.blob(rawType: "BINARY(16)")))
        #expect(!BinaryTextDecoder.padsToFixedWidth(.blob(rawType: "VARBINARY(16)")))
        #expect(!BinaryTextDecoder.padsToFixedWidth(.blob(rawType: "LONGBLOB")))
        #expect(!BinaryTextDecoder.padsToFixedWidth(.text(rawType: "BINARY")))
        #expect(!BinaryTextDecoder.padsToFixedWidth(nil))
    }

    @Test("A NUL inside the value is still binary")
    func embeddedNulRejected() {
        let embedded = Data([0x68, 0x00, 0x69])
        #expect(BinaryTextDecoder.decode(embedded) == nil)
    }

    @Test("An all-padding value reads as empty rather than as binary")
    func allPaddingIsEmpty() {
        let allNul = Data(repeating: 0, count: 16)
        #expect(BinaryTextDecoder.decode(allNul, columnType: .blob(rawType: "BINARY(16)")) == "")
        #expect(BinaryTextDecoder.decode(allNul, columnType: .blob(rawType: "BLOB")) == nil)
    }

    @Test("No bytes read as empty")
    func emptyIsEmpty() {
        #expect(BinaryTextDecoder.decode(Data()) == "")
    }

    @Test("A cut that splits a UTF-8 sequence gives back the characters before it")
    func truncationBacksOffASplitSequence() {
        let data = Data("héllo".utf8)
        let mark = BinaryTextDecoder.truncationMarker
        #expect(BinaryTextDecoder.decode(data, maxBytes: 2) == "h" + mark)
        #expect(BinaryTextDecoder.decode(data, maxBytes: 4) == "hél" + mark)
    }

    @Test("A cut value does not have padding trimmed for it")
    func truncationDoesNotTrimPadding() {
        let data = Data([0x68, 0x00, 0x00, 0x00])
        #expect(BinaryTextDecoder.decode(data, columnType: .blob(rawType: "BINARY(4)"), maxBytes: 2) == nil)
    }

    @Test("A value longer than the cap is marked, so a copy cannot pass a prefix off as the whole")
    func longValueIsCappedAndMarked() throws {
        let data = Data(String(repeating: "a", count: BinaryTextDecoder.maxDisplayBytes + 500).utf8)
        let decoded = try #require(BinaryTextDecoder.decode(data))

        #expect(decoded.hasSuffix(BinaryTextDecoder.truncationMarker))
        #expect(decoded.count == BinaryTextDecoder.maxDisplayBytes + 1)
    }

    @Test("A value at the cap is whole, so it carries no marker")
    func valueAtTheCapIsNotMarked() throws {
        let data = Data(String(repeating: "a", count: BinaryTextDecoder.maxDisplayBytes).utf8)
        let decoded = try #require(BinaryTextDecoder.decode(data))

        #expect(decoded.count == BinaryTextDecoder.maxDisplayBytes)
        #expect(!decoded.hasSuffix(BinaryTextDecoder.truncationMarker))
    }

    @Test("A driver's byte-per-character string decodes the same way")
    func isoLatin1StringDecodes() {
        let carrier = String(data: Data("café".utf8), encoding: .isoLatin1)
        #expect(BinaryTextDecoder.decode(isoLatin1: carrier ?? "") == "café")
    }

    @Test("A byte-per-character string of binary decodes to nothing")
    func isoLatin1BinaryRejected() {
        let carrier = String(data: Data([0x89, 0x50, 0x4E, 0x47]), encoding: .isoLatin1)
        #expect(BinaryTextDecoder.decode(isoLatin1: carrier ?? "") == nil)
    }
}
