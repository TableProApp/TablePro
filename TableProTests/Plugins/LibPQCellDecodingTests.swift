//
//  LibPQCellDecodingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("LibPQCellDecoding")
struct LibPQCellDecodingTests {
    private static let textOid: UInt32 = 25
    private static let booleanOid: UInt32 = 16
    private static let byteaOid: UInt32 = 17

    private func decode(_ bytes: [UInt8], oid: UInt32 = textOid) -> PluginCellValue {
        bytes.withUnsafeBytes { LibPQCellDecoding.value(from: $0, oid: oid) }
    }

    @Test("UTF-8 text decodes as written")
    func utf8Text() {
        #expect(decode(Array("メール café".utf8)) == .text("メール café"))
    }

    @Test("Bytes that are not UTF-8 become replacement characters, never Latin 1 guesses")
    func invalidUTF8IsNotFabricated() {
        let eucJPMail: [UInt8] = [0xA5, 0xE1, 0xA1, 0xBC, 0xA5, 0xEB]
        guard case .text(let text) = decode(eucJPMail) else {
            Issue.record("expected text")
            return
        }
        #expect(text.contains("\u{FFFD}"))
        #expect(text != "¥á¡¼¥ë")
    }

    @Test("A Latin 1 byte on its own is a replacement character, not é")
    func latin1ByteIsReplaced() {
        #expect(decode([0x63, 0x61, 0x66, 0xE9]) == .text("caf\u{FFFD}"))
    }

    @Test("Empty text stays empty")
    func emptyText() {
        #expect(decode([]) == .text(""))
    }

    @Test("Boolean t and f read as true and false")
    func booleans() {
        #expect(decode(Array("t".utf8), oid: Self.booleanOid) == .text("true"))
        #expect(decode(Array("f".utf8), oid: Self.booleanOid) == .text("false"))
    }

    @Test("bytea hex decodes to its bytes")
    func byteaHex() {
        #expect(decode(Array("\\xdeadbeef".utf8), oid: Self.byteaOid) == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }

    @Test("A bytea value that is not in a bytea format stays text")
    func byteaFallsBackToText() {
        #expect(decode(Array("\\xzz".utf8), oid: Self.byteaOid) == .text("\\xzz"))
    }
}
