//
//  MySQLCharacterSetTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("MySQL character set decoding")
struct MySQLCharacterSetTests {
    private func decode(_ bytes: [UInt8], as name: String) -> String {
        bytes.withUnsafeBytes { MySQLCharacterSet(serverName: name).decode($0) }
    }

    @Test("Server names are normalized, and utf8 means utf8mb3")
    func namesAreNormalized() {
        #expect(MySQLCharacterSet(serverName: "UTF8").name == "utf8mb3")
        #expect(MySQLCharacterSet(serverName: " latin1 ") == .latin1)
        #expect(MySQLCharacterSet(serverName: "utf8mb4") == .utf8mb4)
    }

    @Test("UTF-8 text decodes as UTF-8")
    func utf8Decodes() {
        #expect(decode(Array("メール・記事紐付け".utf8), as: "utf8mb4") == "メール・記事紐付け")
        #expect(decode(Array("😀".utf8), as: "utf8mb4") == "😀")
    }

    @Test("Invalid UTF-8 is marked with a replacement character, not reinvented as Latin 1")
    func invalidUTF8IsNotFabricated() {
        #expect(decode([0x61, 0xFF, 0x62], as: "utf8mb4") == "a\u{FFFD}b")
        #expect(decode([0x63, 0x61, 0x66, 0xE9], as: "utf8mb3") == "caf\u{FFFD}")
    }

    @Test("A latin1 column holding UTF-8 bytes reads as that UTF-8")
    func latin1HoldingUTF8() {
        #expect(decode([0xE3, 0x83, 0xA1], as: "latin1") == "メ")
    }

    @Test("A latin1 column holding Latin 1 text uses MySQL's own latin1, which is cp1252")
    func latin1IsWindows1252() {
        #expect(decode([0x69, 0x74, 0x92, 0x73, 0x20, 0x35, 0x80], as: "latin1") == "it’s 5€")
        #expect(decode([0x63, 0x61, 0x66, 0xE9], as: "latin1") == "café")
    }

    @Test("Charsets Foundation decodes byte-for-byte like the server use Foundation")
    func foundationCharsets() {
        #expect(decode([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], as: "cp1251") == "Привет")
        #expect(decode([0xB1, 0xE6], as: "latin2") == "ąć")
        #expect(decode([0x83, 0x81, 0x81, 0x5B, 0x83, 0x8B, 0x5C], as: "cp932") == "メール\\")
        #expect(decode([0xD6, 0xD0, 0xCE, 0xC4], as: "gbk") == "中文")
        #expect(decode([0x30, 0xE1, 0x30, 0xFC], as: "utf16") == "メー")
        #expect(decode([0xE1, 0x30, 0xFC, 0x30], as: "utf16le") == "メー")
    }

    @Test("A byte a single-byte charset leaves undefined becomes one replacement character")
    func undefinedSingleByteKeepsTheRest() {
        #expect(decode([0x61, 0x81, 0x62], as: "cp1250") == "a\u{FFFD}b")
    }

    @Test("Charsets whose Foundation mapping disagrees with the server are not in the table")
    func mismatchedCharsetsAreExcluded() {
        let decodable = Set(MySQLCharacterSet.singleByteDecodedNames + MySQLCharacterSet.multiByteDecodedNames)
        for name in ["sjis", "ujis", "eucjpms", "big5", "euckr", "greek", "hebrew", "koi8r", "koi8u", "cp866", "latin7", "tis620"] {
            #expect(!decodable.contains(name), "\(name)")
        }
    }

    @Test("A charset without a verified decoder reads valid UTF-8 as UTF-8")
    func unknownCharsetFallsBackToUTF8() {
        #expect(decode(Array("abc".utf8), as: "armscii8") == "abc")
        #expect(decode([0x61, 0xFF], as: "armscii8") == "a\u{FFFD}")
    }
}
