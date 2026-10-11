//
//  SQLDumpEncodingChoiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTabularIO
import Testing

struct SQLDumpEncodingChoiceTests {
    private func choice(_ bytes: Data, replacing selected: ImportEncoding = .utf8, family: TransactionEngineFamily = .mysql) -> ImportEncoding? {
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
        #expect(choice(bytes).map { !$0.canHideABackslashInsideACharacter } ?? true)

        let latin1 = Data([0x2F, 0x2A, 0x21, 0x34, 0x30, 0x31, 0x30, 0x31] + Array(" SET NAMES latin1 */;\nINSERT INTO t VALUES ('Caf".utf8)
            + [0xE9, 0x5C, 0x27] + Array("s');\n".utf8))
        #expect(choice(latin1) == .windows1252)
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
        #expect(choice(mysql) == .shiftJIS)
        let postgres = try shiftJIS("SET client_encoding = 'SJIS';\nINSERT INTO t VALUES ('日本語');\n")
        #expect(choice(postgres, family: .postgres) == .shiftJIS)
    }

    @Test("An undeclared EUC-JP or Latin-1 script is read in the encoding it looks like")
    func undeclaredSafeEncodingsArePicked() throws {
        let euc = try #require("INSERT INTO t VALUES ('日本語のテキストです', '東京都港区');\n".data(using: .japaneseEUC))
        #expect(choice(euc) == .eucJP)
        let western = try #require("INSERT INTO t VALUES ('Müller', 'Straße', 'Café crème');\n".data(using: .windowsCP1252))
        #expect(choice(western) == .windows1252)
    }

    @Test("A declaration matching the chosen encoding changes nothing")
    func declarationMatchingTheChoice() throws {
        let bytes = Data("/*!40101 SET NAMES utf8mb4 */;\nINSERT INTO t VALUES ('x');\n".utf8)
        #expect(choice(bytes) == nil)
        #expect(SQLDumpEncodingChoice.declaredEncoding(in: bytes, family: .mysql, grammar: TestGrammar.mysql) == .utf8)
    }
}
