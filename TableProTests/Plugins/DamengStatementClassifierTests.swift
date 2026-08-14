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

    @Test("caps a single select on the server")
    func capsSingleSelect() {
        let capped = DamengStatementClassifier.applyingRowCap(50, to: "SELECT * FROM sample;")
        #expect(capped.contains("SELECT * FROM ("))
        #expect(capped.contains("SELECT * FROM sample"))
        #expect(capped.hasSuffix("WHERE ROWNUM <= 51"))
    }

    @Test("does not overflow the maximum row cap")
    func maximumCapDoesNotOverflow() {
        let capped = DamengStatementClassifier.applyingRowCap(Int.max, to: "SELECT 1")
        #expect(capped.hasSuffix("WHERE ROWNUM <= \(Int.max)"))
    }

    @Test("does not rewrite multiple statements")
    func rejectsMultipleStatements() {
        let query = "SELECT 1; DROP TABLE sample"
        #expect(DamengStatementClassifier.applyingRowCap(10, to: query) == query)
    }

    @Test("keeps semicolons in quoted strings")
    func allowsQuotedSemicolons() {
        let capped = DamengStatementClassifier.applyingRowCap(10, to: "SELECT ';' FROM DUAL;")
        #expect(capped.hasSuffix("WHERE ROWNUM <= 11"))
    }

    @Test("keeps semicolons in Dameng alternative quotes")
    func allowsAlternativeQuotedSemicolons() {
        for query in [
            "SELECT q'[;]' FROM DUAL;",
            "SELECT Q'(;)' FROM DUAL;",
            "SELECT q'{;}' FROM DUAL;",
            "SELECT q'<;>' FROM DUAL;",
            "SELECT q'!;!' FROM DUAL;"
        ] {
            let capped = DamengStatementClassifier.applyingRowCap(10, to: query)
            #expect(capped.hasSuffix("WHERE ROWNUM <= 11"))
        }
    }

    @Test("does not rewrite nonpositive caps or writes")
    func ignoresUnsupportedCaps() {
        #expect(DamengStatementClassifier.applyingRowCap(nil, to: "SELECT 1") == "SELECT 1")
        #expect(DamengStatementClassifier.applyingRowCap(0, to: "SELECT 1") == "SELECT 1")
        #expect(DamengStatementClassifier.applyingRowCap(10, to: "DELETE FROM sample") == "DELETE FROM sample")
    }
}
