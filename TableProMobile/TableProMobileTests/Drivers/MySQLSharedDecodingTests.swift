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

    /// Measured on 4.1.22: `SHOW` string columns arrive as charset 63 with the bytes already in UTF-8.
    @Test("A binary-labelled SHOW string reads as text when asked, and stays bytes otherwise")
    func legacyShowStringsAreText() {
        let decoding = MySQLColumnDecoding(
            typeRaw: 253, charsetnr: 63, characterSetName: "binary", binaryStringsAreText: true
        )
        #expect(decoding == .utf8TextOrBytes)
        #expect(MySQLColumnDecoding(typeRaw: 253, charsetnr: 63, characterSetName: "binary") == .bytes)
    }

    /// Measured on 4.1.22 with `language=/usr/local/mysql/share/mysql/korean/`: the 1064 text arrives in
    /// EUC-KR after `SET NAMES utf8`, and decoding it as Latin 1 was the mojibake.
    @Test("Error text from a Korean 4.1 server reads as Korean")
    func legacyErrorTextUsesTheLanguageCharset() {
        let bytes: [UInt8] = [
            39, 83, 81, 76, 32, 177, 184, 185, 174, 191, 161, 32, 191, 192, 183, 249, 176, 161, 32, 192, 214, 189,
            192, 180, 207, 180, 217, 46, 39, 32, 191, 161, 183, 175, 32, 176, 176, 192, 190, 180, 207, 180, 217, 46,
            32, 40, 39, 84, 65, 66, 76, 69, 83, 32, 70, 82, 79, 77, 32, 96, 106, 117, 95, 109, 105, 106, 117, 105,
            116, 95, 110, 101, 119, 96, 39, 32, 184, 237, 183, 201, 190, 238, 32, 182, 243, 192, 206, 32, 49, 41
        ]
        let language = MySQLErrorText.encoding(forLanguageDirectory: "/usr/local/mysql/share/mysql/korean/")
        let text = bytes.withUnsafeBytes { MySQLErrorText.decode($0, language: language, encoding: .utf8) }
        #expect(text == "'SQL 구문에 오류가 있습니다.' 에러 같읍니다. ('TABLES FROM `ju_mijuit_new`' 명령어 라인 1)")
    }

    @Test("A BLOB column reports a binary type name, so the grid does not search it as text")
    func blobTypeName() {
        let blob = mariaDBTypeName(typeRaw: 252, flags: mysqlBinaryFlag, charsetnr: 63, length: 100)
        #expect(blob == "BLOB")
        #expect(mariaDBTypeName(typeRaw: 254, flags: mysqlBinaryFlag, charsetnr: 63, length: 16) == "BINARY")
        #expect(mariaDBTypeName(typeRaw: 252, flags: 0, charsetnr: 45, length: 100) == "TEXT")
    }
}
