import Foundation
import TableProDamengCore
import TableProSQLGrammar
import Testing

struct DamengScriptSplitterTests {
    // Each passed the gate as one safe read, and the driver sent `DROP TABLE accounts` on its own.
    @Test("A text DM8 reads as one statement is sent whole", arguments: [
        "SELECT 1 FROM DUAL /* /* */ -- */ ; DROP TABLE accounts",
        "SELECT 1 FROM DUAL // ; DROP TABLE accounts",
    ], [false, true])
    func readsCommentsAsDM8Does(sql: String, backslashEscapes: Bool) {
        #expect(DamengScriptSplitter.statements(in: sql, backslashEscapes: backslashEscapes).count == 1)
    }

    // The statement counts DM8 V8 produced, from SQLLexicalCorpusTests.
    @Test("A script is cut where DM8 cuts it", arguments: [
        ("SELECT 'C:\\' AS p; DROP TABLE lexer_canary", false, 2),
        ("SELECT 'C:\\' AS p; DROP TABLE lexer_canary", true, 1),
        ("SELECT 1 /* /* */ ' */; DROP TABLE lexer_canary; --'", false, 1),
        ("SELECT q'[it's]' FROM dual; DROP TABLE lexer_canary; --'", false, 2),
        ("SELECT 1 FROM DUAL // '\n; DELETE FROM lexer_canary; -- '", false, 2),
        ("SELECT 1 -- x\r; DROP TABLE lexer_canary", false, 2),
    ])
    func cutsWhereDM8Cuts(sql: String, backslashEscapes: Bool, count: Int) {
        #expect(DamengScriptSplitter.statements(in: sql, backslashEscapes: backslashEscapes).count == count)
    }

    @Test("The cut is the one the app runs a Dameng session's text with")
    func matchesTheExecutionReading() {
        let session = SQLSessionLexicalFacts(determined: .backslashEscapesInSingleQuotes, enabled: [])
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: "Dameng", declared: nil, session: session).execution
        let script = "CREATE TABLE \"t\" (\"id\" INT); COMMENT ON COLUMN \"t\".\"id\" IS 'a;b'; CREATE INDEX \"i\" ON \"t\" (\"id\");"
        #expect(DamengScriptSplitter.statements(in: script, backslashEscapes: false)
            == SQLStatementScanner.allStatements(in: script, grammar: grammar))
        #expect(DamengScriptSplitter.statements(in: script, backslashEscapes: false).count == 3)
    }

    @Test("A script with a PL/SQL block is sent as it came", arguments: [
        "BEGIN EXECUTE IMMEDIATE 'SET SCHEMA \"S\"'; END;",
        "CREATE OR REPLACE PROCEDURE p AS v INT; BEGIN v := 1; END;",
        "SELECT CASE WHEN a THEN 1 END FROM t; SELECT 2 FROM t",
    ])
    func blockStaysWhole(sql: String) {
        #expect(DamengScriptSplitter.statements(in: sql, backslashEscapes: false) == [sql])
    }

    @Test("A block keyword inside a literal or a comment does not stop the cut")
    func quotedKeywordDoesNotStopTheCut() {
        let script = "SELECT 'BEGIN' FROM t; /* END */ SELECT \"LOOP\" FROM t"
        #expect(DamengScriptSplitter.statements(in: script, backslashEscapes: false).count == 2)
    }

    @Test("A piece holding only a comment is not a statement")
    func commentOnlyPieceDropped() {
        #expect(DamengScriptSplitter.statements(in: "SELECT 1; -- done\n", backslashEscapes: false) == ["SELECT 1"])
    }
}

struct DamengPlaceholdersTests {
    @Test("A ? inside a comment, a literal or a quoted name is not a placeholder", arguments: [
        ("SELECT ? FROM t // ?\nWHERE a = ?", 2),
        ("SELECT ? /* /* ? */ FROM t WHERE a = ?", 2),
        ("SELECT '?', \"?\", q'[?]' FROM t WHERE a = ?", 1),
        ("SELECT ? -- ?\r, ? FROM t", 2),
    ])
    func countsPlaceholdersInCode(template: String, placeholders: Int) {
        #expect(DamengPlaceholders.pieces(of: template, backslashEscapes: false).count == placeholders + 1)
    }

    @Test("A backslash closes no literal unless the session escapes with it")
    func backslashFollowsTheSession() {
        let template = "SELECT 'a\\' , ? FROM t WHERE b = '?'"
        #expect(DamengPlaceholders.pieces(of: template, backslashEscapes: false).count == 2)
        #expect(DamengPlaceholders.pieces(of: template, backslashEscapes: true).count == 2)
        #expect(DamengPlaceholders.pieces(of: "SELECT 'a\\'' , ?", backslashEscapes: true).count == 2)
        #expect(DamengPlaceholders.pieces(of: "SELECT 'a\\'' , ?", backslashEscapes: false).count == 1)
    }

    @Test("The pieces put back together are the template")
    func piecesRoundTrip() {
        let template = "INSERT INTO \"t\" (\"a?\", \"b\") VALUES (?, ?) -- ?"
        #expect(DamengPlaceholders.pieces(of: template, backslashEscapes: false).joined(separator: "?") == template)
    }
}

struct DamengStatementClassifierTests {
    @Test("The first keyword is read past comments the way DM8 ends them", arguments: [
        ("// x\nSELECT 1 FROM DUAL", true),
        ("/* /* */ DELETE FROM t -- */ SELECT 1", false),
        ("-- a\u{2028}SELECT 1\nDELETE FROM t", false),
        ("\u{FEFF}( SELECT 1 FROM DUAL)", true),
        ("'SELECT'", false),
    ])
    func readsTheFirstKeyword(sql: String, isRead: Bool) {
        #expect(DamengStatementClassifier.isReadOnly(sql) == isRead)
    }

    @Test("Rows are expected from a result statement")
    func expectsRows() {
        #expect(DamengStatementClassifier.likelyReturnsRows("WITH a AS (SELECT 1 FROM DUAL) SELECT * FROM a"))
        #expect(!DamengStatementClassifier.likelyReturnsRows("UPDATE t SET a = 1"))
    }
}
