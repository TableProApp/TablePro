import Testing
@testable import TablePro

@Suite("Dameng statement classifier")
struct DamengStatementClassifierTests {
    @Test("recognizes row-producing statements after comments")
    func recognizesRowStatements() {
        #expect(DamengStatementClassifier.expectsRows("/* nested /* note */ */ SELECT 1"))
        #expect(DamengStatementClassifier.expectsRows("-- note\nWITH value AS (SELECT 1) SELECT * FROM value"))
        #expect(DamengStatementClassifier.expectsRows("EXPLAIN SELECT 1"))
        #expect(!DamengStatementClassifier.expectsRows("UPDATE sample SET value = 1"))
    }

    @Test("recognizes a select behind a byte order mark or exotic whitespace")
    func recognizesRowStatementsAfterUnusualWhitespace() {
        #expect(DamengStatementClassifier.expectsRows("\u{FEFF}SELECT 1"))
        #expect(DamengStatementClassifier.expectsRows("\u{00A0}SELECT 1"))
        #expect(DamengStatementClassifier.expectsRows("\u{000B}\u{000C}SELECT 1"))
        #expect(DamengStatementClassifier.expectsRows("\u{2028}-- note\nSELECT 1"))
        #expect(!DamengStatementClassifier.expectsRows("\u{FEFF}UPDATE sample SET value = 1"))
    }

    @Test("returns no keyword for statements that never reach one")
    func ignoresStatementsWithoutAKeyword() {
        #expect(!DamengStatementClassifier.expectsRows(""))
        #expect(!DamengStatementClassifier.expectsRows("   \n\t "))
        #expect(!DamengStatementClassifier.expectsRows("-- only a comment"))
        #expect(!DamengStatementClassifier.expectsRows("/* unterminated"))
        #expect(!DamengStatementClassifier.expectsRows("123"))
    }
}
