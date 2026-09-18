//
//  MySQLLatin1Tests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("MySQL latin1")
struct MySQLLatin1Tests {
    private static let serverUTF8ForUpperHalf: [String] = [
        "E282AC", "C281", "E2809A", "C692", "E2809E", "E280A6", "E280A0", "E280A1",
        "CB86", "E280B0", "C5A0", "E280B9", "C592", "C28D", "C5BD", "C28F",
        "C290", "E28098", "E28099", "E2809C", "E2809D", "E280A2", "E28093", "E28094",
        "CB9C", "E284A2", "C5A1", "E280BA", "C593", "C29D", "C5BE", "C5B8",
        "C2A0", "C2A1", "C2A2", "C2A3", "C2A4", "C2A5", "C2A6", "C2A7",
        "C2A8", "C2A9", "C2AA", "C2AB", "C2AC", "C2AD", "C2AE", "C2AF",
        "C2B0", "C2B1", "C2B2", "C2B3", "C2B4", "C2B5", "C2B6", "C2B7",
        "C2B8", "C2B9", "C2BA", "C2BB", "C2BC", "C2BD", "C2BE", "C2BF",
        "C380", "C381", "C382", "C383", "C384", "C385", "C386", "C387",
        "C388", "C389", "C38A", "C38B", "C38C", "C38D", "C38E", "C38F",
        "C390", "C391", "C392", "C393", "C394", "C395", "C396", "C397",
        "C398", "C399", "C39A", "C39B", "C39C", "C39D", "C39E", "C39F",
        "C3A0", "C3A1", "C3A2", "C3A3", "C3A4", "C3A5", "C3A6", "C3A7",
        "C3A8", "C3A9", "C3AA", "C3AB", "C3AC", "C3AD", "C3AE", "C3AF",
        "C3B0", "C3B1", "C3B2", "C3B3", "C3B4", "C3B5", "C3B6", "C3B7",
        "C3B8", "C3B9", "C3BA", "C3BB", "C3BC", "C3BD", "C3BE", "C3BF"
    ]

    private static let reporterMojibakeUTF8 =
        "C3A3C692C2A1C3A3C692C2BCC3A3C692C2ABC3A3C692C2BBC3A8C2A8CB9CC3A4C2BAE280B9C3A7C2B4C290C3A4C2BBCB9CC3A3C281E28098"

    private func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02X", $0) }.joined()
    }

    private func text(fromHex hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    @Test("Every byte decodes to what MySQL 8.4 itself converts it to")
    func everyByteMatchesTheServer() {
        for byte in 0...255 {
            let decoded = MySQLLatin1.decode([UInt8(byte)])
            let expected = byte < 0x80 ? String(format: "%02X", byte) : Self.serverUTF8ForUpperHalf[byte - 0x80]
            #expect(hex(decoded) == expected, "byte \(String(format: "%02X", byte))")
        }
    }

    @Test("The five bytes cp1252 leaves undefined pass through as C1 controls")
    func undefinedWindowsBytesPassThrough() {
        #expect(MySQLLatin1.decode([0x81, 0x8D, 0x8F, 0x90, 0x9D]) == "\u{81}\u{8D}\u{8F}\u{90}\u{9D}")
    }

    @Test("Every byte round-trips through its character")
    func everyByteRoundTrips() {
        let all = (0...255).map { UInt8($0) }
        #expect(MySQLLatin1.bytes(representing: MySQLLatin1.decode(all)) == all)
    }

    @Test("A character MySQL latin1 has no byte for is not representable")
    func unrepresentableCharacters() {
        #expect(MySQLLatin1.bytes(representing: "メ") == nil)
        #expect(MySQLLatin1.bytes(representing: "\u{80}") == nil)
        #expect(MySQLLatin1.bytes(representing: "\u{0301}") == nil)
    }

    @Test("The #2725 comment is repaired back to the Japanese it was written as")
    func repairsTheReportedComment() {
        let stored = text(fromHex: Self.reporterMojibakeUTF8)
        #expect(stored.hasPrefix("ãƒ¡"))
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8(stored) == "メール・記事紐付け")
    }

    @Test("Text that was stored correctly is left alone")
    func correctTextIsUnchanged() {
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8("メール・記事紐付け") == "メール・記事紐付け")
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8("café") == "café")
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8("it’s 5€") == "it’s 5€")
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8("plain ascii") == "plain ascii")
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8("") == "")
    }

    @Test("Mixed correct and double-encoded text is left alone")
    func mixedTextIsUnchanged() {
        let mixed = "メール " + text(fromHex: "C3A3C692C2A1")
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8(mixed) == mixed)
    }

    @Test("Latin 1 text whose bytes form UTF-8 reads as that UTF-8, like a latin1 client would")
    func latin1TextFormingUTF8IsRead() {
        #expect(MySQLLatin1.repairingDoubleEncodedUTF8("Ã©") == "é")
    }
}
