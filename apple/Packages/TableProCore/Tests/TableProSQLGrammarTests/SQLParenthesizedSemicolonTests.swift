import Foundation
import TableProSQLGrammar
import Testing

struct SQLParenthesizedSemicolonTests {
    private static func grammar(_ typeId: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
    }

    private func sent(_ sql: String, _ grammar: SQLLexicalGrammar) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    @Test("A PostgreSQL rule's multi-command action list stays one statement", arguments: [
        "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))",
        "CREATE OR REPLACE RULE r AS ON UPDATE TO t WHERE (NEW.a > 0) DO INSTEAD (UPDATE a SET n = 1; NOTIFY t)",
        "CREATE RULE r AS ON DELETE TO t DO (DELETE FROM a; DELETE FROM b)",
    ])
    func ruleActionStaysWhole(rule: String) {
        let grammar = Self.grammar("PostgreSQL")
        let sql = rule + ";\nSELECT 9;"

        #expect(sent(sql, grammar) == [rule, "SELECT 9"])
        #expect(SQLStatementScanner.navigableStatements(in: sql, grammar: grammar).count == 2)
        #expect(!SQLStatementScanner.endsInsideOpenBlock(sql, grammar: grammar))
    }

    @Test("A rule whose action is one command ends at its ;")
    func ruleWithoutAnActionList() {
        let grammar = Self.grammar("PostgreSQL")

        #expect(sent("CREATE RULE r AS ON INSERT TO t DO ALSO INSERT INTO log VALUES (NEW.id);\nSELECT 2;", grammar).count == 2)
        #expect(sent("CREATE RULE r AS ON INSERT TO t DO INSTEAD NOTHING;\nSELECT 2;", grammar).count == 2)
    }

    @Test("A stray ( ends at its ; and leaves every statement after it on its own", arguments: [
        "PostgreSQL", "MySQL", "SQLite", "SQL Server", "DuckDB", "ClickHouse",
    ])
    func strayParenthesisEndsAtItsSemicolon(typeId: String) {
        let grammar = Self.grammar(typeId)
        let sql = "SELECT 1;\nSELECT count(id FROM a;\nSELECT 2;\nSELECT 3;"
        let caret = (sql as NSString).range(of: "SELECT 3").location

        #expect(sent(sql, grammar) == ["SELECT 1", "SELECT count(id FROM a", "SELECT 2", "SELECT 3"])
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: caret, grammar: grammar) == "SELECT 3")
        #expect(!SQLStatementScanner.endsInsideOpenBlock(sql, grammar: grammar))
    }

    @Test("A rule's action list left open holds the rest of the text, which the gate reads as more than one statement")
    func openActionListLeavesTheTextInsideABlock() {
        let grammar = Self.grammar("PostgreSQL")
        let sql = "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1);\nDROP TABLE users;"

        #expect(sent(sql, grammar).count == 1)
        #expect(SQLStatementScanner.endsInsideOpenBlock(sql, grammar: grammar))
    }

    @Test("The gate tiers each command a rule's action list holds")
    func gateTiersThePieces() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)

        #expect(SQLStatementClassifier.deletesEveryRow(
            "CREATE RULE r AS ON INSERT TO t DO ALSO (SELECT 1; DELETE FROM audit)",
            databaseTypeId: "PostgreSQL",
            readings: readings
        ))
        #expect(SQLStatementClassifier.classify(
            "SELECT (1; DROP TABLE users; SELECT 1)", databaseTypeId: "PostgreSQL", readings: readings
        ).tier == .destructive)
    }

    @Test("Inside a routine body a parenthesis one statement leaves open does not hide the body's END")
    func bodyStatementParenthesisDoesNotHideTheEnd() {
        let sql = "CREATE PROCEDURE p()\nBEGIN\n  SELECT (1;\n  SELECT 2;\nEND;\nSELECT 3;"
        #expect(sent(sql, Self.grammar("MySQL")).last == "SELECT 3")
    }
}
