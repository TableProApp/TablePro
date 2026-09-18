import Foundation
@testable import TableProMobile
import Testing

@Suite("MySQL shared decoding on iOS")
struct MySQLSharedDecodingTests {
    @Test("The connection's Encoding field reaches the driver")
    func encodingFieldIsRead() {
        #expect(MySQLConnectionEncoding(additionalFields: [:]) == .utf8)
        #expect(MySQLConnectionEncoding(additionalFields: ["mysqlConnectionEncoding": ""]) == .utf8)
        #expect(
            MySQLConnectionEncoding(additionalFields: ["mysqlConnectionEncoding": "utf8ViaLatin1"]) == .utf8ViaLatin1
        )
    }

    @Test("Text written through a Latin 1 connection reads as UTF-8 under the legacy encoding")
    func legacyTextIsRepaired() {
        let stored = String(bytes: [0xC3, 0xA3, 0xC6, 0x92, 0xC2, 0xA1], encoding: .utf8) ?? ""
        #expect(MySQLConnectionEncoding.utf8.presentedText(stored) == stored)
        #expect(MySQLConnectionEncoding.utf8ViaLatin1.presentedText(stored) == "メ")
    }

    @Test("A latin1 column holding Latin 1 text uses MySQL's own latin1 table")
    func latin1ColumnsDecode() {
        let bytes: [UInt8] = [0x69, 0x74, 0x92, 0x73, 0x20, 0x35, 0x80]
        let decoded = bytes.withUnsafeBytes { MySQLCharacterSet(serverName: "latin1").decode($0) }
        #expect(decoded == "it’s 5€")
    }

    @Test("A binary column stays bytes and a text column stays text")
    func columnKindsSurvive() {
        #expect(MySQLColumnDecoding(typeRaw: 252, charsetnr: 63, characterSetName: "binary") == .bytes)
        #expect(MySQLColumnDecoding(typeRaw: 253, charsetnr: 45, characterSetName: "utf8mb4") == .text(.utf8mb4))
    }

    @Test("A BLOB column reports a binary type name, so the grid does not search it as text")
    func blobTypeName() {
        let blob = mariaDBTypeName(typeRaw: 252, flags: mysqlBinaryFlag, charsetnr: 63, length: 100)
        #expect(blob == "BLOB")
        #expect(mariaDBTypeName(typeRaw: 254, flags: mysqlBinaryFlag, charsetnr: 63, length: 16) == "BINARY")
        #expect(mariaDBTypeName(typeRaw: 252, flags: 0, charsetnr: 45, length: 100) == "TEXT")
    }
}
