//
//  MySQLLiteralSpellingTests.swift
//  TableProTests
//
//  Every expected spelling was run against MySQL 8.4.11 and MariaDB 13.0.2 with and without
//  NO_BACKSLASH_ESCAPES, and each server stored the characters the test names.
//

import Foundation
import Testing

struct MySQLLiteralSpellingTests {
    private let session = MySQLLiteralSpelling.quoteDoubling

    @Test("Only a session that reports NO_BACKSLASH_ESCAPES loses backslash escapes")
    func spellingFollowsTheStatusFlag() {
        #expect(MySQLLiteralSpelling(noBackslashEscapes: true) == .quoteDoubling)
        #expect(MySQLLiteralSpelling(noBackslashEscapes: false) == .backslashEscapes)
        #expect(MySQLLiteralSpelling(noBackslashEscapes: nil) == .backslashEscapes)
    }

    @Test("A session with backslash escapes gets the statement exactly as written")
    func backslashSessionIsUntouched() {
        let sql = #"ALTER TABLE `t` MODIFY COLUMN `c` varchar(20) NULL DEFAULT 'x\\y' COMMENT 'a\nb'"#
        #expect(MySQLLiteralSpelling.backslashEscapes.respelled(sql) == sql)
    }

    /// Written with backslash escapes, `'x\\y'` stored `x\\y` under NO_BACKSLASH_ESCAPES and doubled
    /// again on every later save of the column.
    @Test("A backslash is written once for a session that reads it literally")
    func backslashIsNotDoubled() {
        let sql = #"ALTER TABLE `t` MODIFY COLUMN `c` varchar(20) NULL DEFAULT 'x\\y'"#
        #expect(session.respelled(sql) == #"ALTER TABLE `t` MODIFY COLUMN `c` varchar(20) NULL DEFAULT 'x\y'"#)
    }

    /// A raw line break inside a literal stores a line break in both modes, where `\n` stored the two
    /// characters `\` and `n` under NO_BACKSLASH_ESCAPES.
    @Test("Control characters are written raw for a session that reads backslashes literally")
    func controlCharactersAreRaw() {
        #expect(session.respelled(#"COMMENT 'a\nb\rc\td\Ze\bf\0g'"#)
            == "COMMENT 'a\nb\rc\td\u{1A}e\u{08}f\u{00}g'")
    }

    @Test("A quote escaped either way comes out doubled", arguments: [#"'it\'s'"#, "'it''s'"])
    func quotesAreDoubled(literal: String) {
        #expect(session.respelled("DEFAULT \(literal)") == "DEFAULT 'it''s'")
    }

    /// The server keeps `\%` and `\_` as two characters outside a pattern, and an unknown escape
    /// stands for the character after it.
    @Test("Pattern escapes keep their backslash and an unknown escape drops it")
    func patternAndUnknownEscapes() {
        #expect(session.respelled(#"LIKE 'a\_b\%c'"#) == #"LIKE 'a\_b\%c'"#)
        #expect(session.respelled(#"'\q'"#) == "'q'")
    }

    /// `SHOW CREATE TABLE` and the catalog print an expression default, a column's ENUM members and
    /// a CHECK clause with backslash escapes whatever the session's mode.
    @Test("Every literal the server printed is re-spelled, introducers and all")
    func serverPrintedSQL() {
        #expect(session.respelled(#"DEFAULT (concat(_utf8mb4'it\'s',_utf8mb4'x\\y'))"#)
            == #"DEFAULT (concat(_utf8mb4'it''s',_utf8mb4'x\y'))"#)
        #expect(session.respelled(#"`k` enum('a\\b','it''s','x')"#) == #"`k` enum('a\b','it''s','x')"#)
        #expect(session.respelled(#"CHECK ((`k` <> _utf8mb4'z\\z'))"#) == #"CHECK ((`k` <> _utf8mb4'z\z'))"#)
    }

    @Test("Identifiers, double-quoted text and comments are copied unchanged")
    func nonLiteralsAreCopied() {
        #expect(session.respelled(#"`we'ird\\col` = 'a\\b'"#) == #"`we'ird\\col` = 'a\b'"#)
        #expect(session.respelled(#""it's\\" = 'a\\b'"#) == #""it's\\" = 'a\b'"#)
        #expect(session.respelled("-- it's\n'a\\\\b'") == "-- it's\n'a\\b'")
        #expect(session.respelled("# it's\n'a\\\\b'") == "# it's\n'a\\b'")
        #expect(session.respelled("/* it's */ 'a\\\\b'") == "/* it's */ 'a\\b'")
        #expect(session.respelled("5--1 'a\\\\b'") == "5--1 'a\\b'")
    }

    @Test("A literal that never closes is left as it was")
    func unterminatedLiteral() {
        #expect(session.respelled(#"DEFAULT 'a\\b"#) == #"DEFAULT 'a\\b"#)
    }

    @Test(
        "Re-spelling a backslash-escaped literal reads back the same text as quoting it for the session",
        arguments: ["C:\\temp\\next", "it's", "line\nbreak", "cr\rtab\t", "nul\u{00}sub\u{1A}bs\u{08}",
                    "form\u{0C}feed", "50%_off", "\\%\\_", "日本語 é", "'\\'", ""]
    )
    func respellingMatchesDirectQuoting(value: String) {
        let written = "'\(MySQLLiteralSpelling.backslashEscapes.escaped(value))'"
        #expect(session.respelled(written) == "'\(session.escaped(value))'")
    }

    /// MySQL and MariaDB have no `\f` escape: `'p\fq'` stored `pfq` on both, a raw form feed stored
    /// `p<FF>q`.
    @Test("A form feed is written as itself")
    func formFeedIsRaw() {
        #expect(mysqlEscapeStringLiteral("p\u{0C}q") == "p\u{0C}q")
    }
}
