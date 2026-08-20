import Testing
@testable import TablePro

@Suite("Dameng statement classifier")
struct DamengStatementClassifierTests {
    @Test("recognizes row-producing statements after comments")
    func recognizesRowStatements() {
        #expect(DamengStatementClassifier.likelyReturnsRows("/* nested /* note */ */ SELECT 1"))
        #expect(DamengStatementClassifier.likelyReturnsRows("-- note\nWITH value AS (SELECT 1) SELECT * FROM value"))
        #expect(DamengStatementClassifier.likelyReturnsRows("EXPLAIN SELECT 1"))
        #expect(!DamengStatementClassifier.likelyReturnsRows("UPDATE sample SET value = 1"))
    }

    @Test("recognizes a select behind a byte order mark or exotic whitespace")
    func recognizesRowStatementsAfterUnusualWhitespace() {
        #expect(DamengStatementClassifier.likelyReturnsRows("\u{FEFF}SELECT 1"))
        #expect(DamengStatementClassifier.likelyReturnsRows("\u{00A0}SELECT 1"))
        #expect(DamengStatementClassifier.likelyReturnsRows("\u{000B}\u{000C}SELECT 1"))
        #expect(DamengStatementClassifier.likelyReturnsRows("\u{2028}-- note\nSELECT 1"))
        #expect(!DamengStatementClassifier.likelyReturnsRows("\u{FEFF}UPDATE sample SET value = 1"))
    }

    @Test("returns no keyword for statements that never reach one")
    func ignoresStatementsWithoutAKeyword() {
        #expect(!DamengStatementClassifier.likelyReturnsRows(""))
        #expect(!DamengStatementClassifier.likelyReturnsRows("   \n\t "))
        #expect(!DamengStatementClassifier.likelyReturnsRows("-- only a comment"))
        #expect(!DamengStatementClassifier.likelyReturnsRows("/* unterminated"))
        #expect(!DamengStatementClassifier.likelyReturnsRows("123"))
    }

    @Test("a misjudged statement costs framing, not its rows")
    func misjudgedStatementsAreOnlyAFramingHint() {
        // MERGE and CALL fall outside the keyword set. The bridge converts whatever columns
        // came back regardless, so a false negative here must not be treated as "no rows".
        #expect(!DamengStatementClassifier.likelyReturnsRows("MERGE INTO target USING source ON (1 = 1)"))
        #expect(!DamengStatementClassifier.likelyReturnsRows("CALL sp_report()"))
    }
}
