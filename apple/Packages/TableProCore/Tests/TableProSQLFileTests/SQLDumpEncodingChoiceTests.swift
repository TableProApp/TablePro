import Foundation
@testable import TableProSQLFile
import TableProSQLGrammar
import TableProTabularIO
import Testing

struct SQLDumpEncodingChoiceTests {
    private static let hidesABackslash: Set<String.Encoding> = [
        TabularTextEncoding.shiftJIS.foundationEncoding,
        TabularTextEncoding.gb18030.foundationEncoding,
        TabularTextEncoding.big5.foundationEncoding,
    ]

    private func choice(_ bytes: Data, replacing selected: String.Encoding = .utf8, family: SQLDumpFamily = .mysql) -> String.Encoding? {
        SQLDumpEncodingChoice.encoding(
            replacing: selected,
            forPreview: bytes,
            isWholeFile: true,
            family: family,
            grammar: family == .mysql ? TestGrammar.mysql : TestGrammar.postgres
        )
    }

    private func shiftJIS(_ text: String) throws -> Data {
        try #require(text.data(using: .shiftJIS, allowLossyConversion: false))
    }

    @Test("A Latin-1 dump whose data reads as Shift JIS is read as the Latin-1 it declares")
    func declaredLatin1OutranksDataThatLooksJapanese() throws {
        var bytes = Data("-- MySQL dump 10.13\n/*!40101 SET NAMES latin1 */;\nINSERT INTO `users` VALUES (1,'".utf8)
        bytes.append(try shiftJIS("日本語テストのデータです"))
        bytes.append(contentsOf: Array("'),(2,'".utf8) + [0xE9, 0x5C, 0x27] + Array("); DROP TABLE users; -- '),(3,'bob');\n".utf8))
        #expect(TabularEncodingDetector.sniff(bytes).encoding == .shiftJIS)
        #expect(choice(bytes).map { !Self.hidesABackslash.contains($0) } ?? true)

        let latin1 = Data([0x2F, 0x2A, 0x21, 0x34, 0x30, 0x31, 0x30, 0x31] + Array(" SET NAMES latin1 */;\nINSERT INTO t VALUES ('Caf".utf8)
            + [0xE9, 0x5C, 0x27] + Array("s');\n".utf8))
        #expect(choice(latin1) == .windowsCP1252)
    }

    @Test("Without a declaration, an encoding that can hide a backslash inside a character is never picked for you")
    func undeclaredShiftJISIsNotPicked() throws {
        var bytes = Data("INSERT INTO t VALUES ('/*!40101 SET NAMES sjis */', '".utf8)
        bytes.append(try shiftJIS("日本語テストのデータです"))
        bytes.append(contentsOf: Array("');\n".utf8))
        #expect(choice(bytes) == nil)
    }

    @Test("A Shift JIS mysqldump or pg_dump that says so is read as Shift JIS")
    func declaredShiftJISIsPicked() throws {
        let mysql = try shiftJIS("/*!40101 SET NAMES cp932 */;\nINSERT INTO t VALUES ('日本語');\n")
        #expect(choice(mysql) == TabularTextEncoding.shiftJIS.foundationEncoding)
        let postgres = try shiftJIS("SET client_encoding = 'SJIS';\nINSERT INTO t VALUES ('日本語');\n")
        #expect(choice(postgres, family: .postgres) == TabularTextEncoding.shiftJIS.foundationEncoding)
    }

    @Test("An undeclared EUC-JP or Latin-1 script is read in the encoding it looks like")
    func undeclaredSafeEncodingsArePicked() throws {
        let euc = try #require("INSERT INTO t VALUES ('日本語のテキストです', '東京都港区');\n".data(using: .japaneseEUC))
        #expect(choice(euc) == TabularTextEncoding.eucJP.foundationEncoding)
        let western = try #require("INSERT INTO t VALUES ('Müller', 'Straße', 'Café crème');\n".data(using: .windowsCP1252))
        #expect(choice(western) == .windowsCP1252)
    }

    @Test("A declaration matching the chosen encoding changes nothing")
    func declarationMatchingTheChoice() throws {
        let bytes = Data("/*!40101 SET NAMES utf8mb4 */;\nINSERT INTO t VALUES ('x');\n".utf8)
        #expect(choice(bytes) == nil)
        #expect(SQLDumpEncodingChoice.declaredEncoding(in: bytes, family: .mysql, grammar: TestGrammar.mysql) == .utf8)
    }

    @Test("A non-UTF-8 byte near the end of a whole file does not read as UTF-8, though a chunk would hold it back")
    func heldBackBytesAtTheEndOfAWholeFileDoNotDecode() {
        var bytes = Data("SET NAMES latin1;\nINSERT INTO t VALUES ('caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Data("');\n".utf8))

        #expect(SQLDumpEncodingChoice.decodedPreview(bytes, as: .utf8, isWholeFile: true) == nil)
        #expect(SQLDumpEncodingChoice.decodedPreview(bytes, as: .utf8, isWholeFile: false) != nil)
        #expect(SQLDumpEncodingChoice.decodedPreview(bytes, as: .windowsCP1252, isWholeFile: true)?.hasSuffix("café');\n") == true)
        #expect(choice(bytes) == .windowsCP1252)
    }
}
