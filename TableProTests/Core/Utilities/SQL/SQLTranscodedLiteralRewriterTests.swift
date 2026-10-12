//
//  SQLTranscodedLiteralRewriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLTranscodedLiteralRewriterTests {
    private func rewritten(_ bytes: [UInt8], as encoding: String.Encoding) throws -> String? {
        let statement = try #require(String(data: Data(bytes), encoding: encoding))
        return try SQLTranscodedLiteralRewriter.rewritten(statement, decodedFrom: encoding, grammar: TestGrammar.mysql)
    }

    @Test("A binary literal read from a Latin-1 dump is sent as the exact bytes it held")
    func binaryLiteralFromLatin1BecomesHex() throws {
        let bytes = Array("INSERT INTO t VALUES (_binary'".utf8) + [0xE9, 0xFF, 0x5C, 0x30, 0x5C, 0x27, 0x27, 0x27, 0x41]
            + Array("',1)".utf8)
        #expect(try rewritten(bytes, as: .isoLatin1) == "INSERT INTO t VALUES (X'E9FF00272741',1)")
    }

    @Test("A binary literal from a Windows-1252 dump keeps its bytes, backslash escapes decoded")
    func binaryLiteralFromWindows1252BecomesHex() throws {
        let bytes = Array("/*!40101 INSERT INTO t VALUES (_binary '".utf8) + [0x80, 0x5C, 0x6E, 0x5C, 0x25]
            + Array("') */".utf8)
        #expect(try rewritten(bytes, as: .windowsCP1252) == "/*!40101 INSERT INTO t VALUES (X'800A5C25') */")
    }

    @Test("A binary literal that cannot be read back exactly stops the import")
    func binaryLiteralFromShiftJISIsRefused() throws {
        let statement = "INSERT INTO t VALUES (_binary'髙橋')"
        #expect(throws: SQLTranscodedLiteralError.unrecoverableBinaryLiteral) {
            try SQLTranscodedLiteralRewriter.rewritten(statement, decodedFrom: .shiftJIS, grammar: TestGrammar.mysql)
        }
    }

    @Test("A text introducer on a non-ASCII literal names the UTF-8 the import sends")
    func textIntroducerBecomesUTF8() throws {
        #expect(try SQLTranscodedLiteralRewriter.rewritten(
            "SELECT _latin1'Café', _sjis \"東京\"",
            decodedFrom: .shiftJIS,
            grammar: TestGrammar.mysql
        ) == "SELECT _utf8mb4'Café', _utf8mb4 \"東京\"")
        #expect(try SQLTranscodedLiteralRewriter.rewritten(
            "SELECT _latin1'Café' COLLATE latin1_german2_ci",
            decodedFrom: .isoLatin1,
            grammar: TestGrammar.mysql
        ) == "SELECT CONVERT(_utf8mb4'Café' USING latin1) COLLATE latin1_german2_ci")
    }

    @Test("ASCII bodies, Unicode introducers, hex literals and plain strings are left alone")
    func literalsLeftAlone() throws {
        let statements = [
            "INSERT INTO t VALUES (_binary'abc\\0', _utf8mb4'日本', _latin1 X'E9', X'E9', 'é')",
            "SELECT my_column FROM t_1 WHERE name = 'Café'",
            "SELECT `_binary` FROM t WHERE x = '_latin1'"
        ]
        for statement in statements {
            #expect(try SQLTranscodedLiteralRewriter.rewritten(statement, decodedFrom: .isoLatin1, grammar: TestGrammar.mysql) == nil)
        }
    }

    @Test("A dump that turns backslash escapes off makes a binary literal holding a backslash stop the import")
    func binaryLiteralWithBackslashNeedsKnownEscapes() throws {
        let statement = "INSERT INTO t VALUES (_binary'\u{E9}\\n')"
        #expect(throws: SQLTranscodedLiteralError.unrecoverableBinaryLiteral) {
            try SQLTranscodedLiteralRewriter.rewritten(
                statement,
                decodedFrom: .isoLatin1,
                backslashEscapesAreOn: false,
                grammar: TestGrammar.mysql
            )
        }
        #expect(try SQLTranscodedLiteralRewriter.rewritten(
            "INSERT INTO t VALUES (_binary'\u{E9}''x')",
            decodedFrom: .isoLatin1,
            backslashEscapesAreOn: false,
            grammar: TestGrammar.mysql
        ) == "INSERT INTO t VALUES (X'E92778')")
    }

    @Test("The session's sql_mode decides whether backslashes escape")
    func sqlModeTracking() {
        func after(_ statement: String, _ isOn: Bool) -> Bool {
            SQLTranscodedLiteralRewriter.backslashEscapesAreOn(after: statement, currently: isOn, grammar: TestGrammar.mysql)
        }
        #expect(after("/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */", true))
        #expect(!after("SET sql_mode = 'ANSI_QUOTES,NO_BACKSLASH_ESCAPES'", true))
        #expect(!after("SET SESSION sql_mode = @OLD_SQL_MODE", true))
        #expect(after("SET GLOBAL sql_mode = 'NO_BACKSLASH_ESCAPES'", true))
        #expect(!after("SET @@session.sql_mode = 'no_backslash_escapes'", true))
        #expect(after("SET sql_mode = DEFAULT", false))
        #expect(after("INSERT INTO t VALUES ('sql_mode')", true))
    }

    @Test("A comment between the literal and COLLATE still keeps the collation valid")
    func collateAfterAComment() throws {
        #expect(try SQLTranscodedLiteralRewriter.rewritten(
            "SELECT _latin1'Café' /* note */ COLLATE latin1_bin",
            decodedFrom: .isoLatin1,
            grammar: TestGrammar.mysql
        ) == "SELECT CONVERT(_utf8mb4'Café' USING latin1) /* note */ COLLATE latin1_bin")
    }
}
