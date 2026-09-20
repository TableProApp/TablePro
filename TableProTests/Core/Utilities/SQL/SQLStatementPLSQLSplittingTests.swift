//
//  SQLStatementPLSQLSplittingTests.swift
//  TableProTests
//
//  Oracle's statements end where its own grammar says, and a PL/SQL unit keeps the `;` after its `END`. The editor
//  used to cut `BEGIN ...; END;` at the inner `;` and strip the final one from every unit, which sent Oracle a fragment
//  and stored every procedure created from the editor INVALID (#2984).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@Suite("SQL statement scanner - Oracle PL/SQL units")
struct SQLStatementPLSQLSplittingTests {
    @Test("Each statement reaches the driver as Oracle accepts it", arguments: PLSQLScriptCorpus.cases)
    func corpusSplitsAsMeasured(example: PLSQLScriptCase) {
        #expect(SQLStatementScanner.allStatements(in: example.script, grammar: TestGrammar.oracle) == example.statements)
    }

    @Test("The reported block runs as one statement at every caret position inside it")
    func caretAnywhereInTheBlockRunsTheBlock() {
        let script = PLSQLScriptCorpus.cases[0].script
        let block = "BEGIN\n  DBMS_OUTPUT.PUT_LINE('Hello from PL/SQL');\nEND;"
        let blockLength = (block as NSString).length
        for caret in 0...blockLength {
            let statement = SQLStatementScanner.statementAtCursor(in: script, cursorPosition: caret, grammar: TestGrammar.oracle)
            #expect(statement == block, "caret \(caret)")
        }
    }

    @Test("The gutter offers each unit once and never a slash line")
    func navigableStatementsSkipSlashLines() {
        let script = "BEGIN NULL; END;\n/\nSELECT 1 FROM dual\n/\n"
        let navigable = SQLStatementScanner.navigableStatements(in: script, grammar: TestGrammar.oracle)
        let texts = navigable.map { (script as NSString).substring(with: $0.contentRange) }
        #expect(texts == ["BEGIN NULL; END;", "SELECT 1 FROM dual"])
    }

    @Test("Located segments still tile the whole document")
    func segmentsTileTheDocument() {
        for example in PLSQLScriptCorpus.cases {
            let located = SQLStatementScanner.locatedStatements(in: example.script, grammar: TestGrammar.oracle)
            #expect(located.map(\.sql).joined() == example.script, "\(example.name)")
        }
    }

    @Test("A unit keeps its terminator and a query does not")
    func terminatorPolicy() {
        let located = SQLStatementScanner.locatedStatements(
            in: "BEGIN NULL; END;\nSELECT 1 FROM dual;",
            grammar: TestGrammar.oracle
        ).filter(\.hasContent)
        #expect(located.map(\.terminator) == [.partOfStatement, .separator])
    }

    @Test("A definition takes no bind parameters and a block or a query does")
    func bindParametersFollowTheStatementKind() {
        let script = """
        CREATE OR REPLACE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN :NEW.a := 1; END;
        BEGIN p(:id); END;
        SELECT * FROM x WHERE a = :a;
        """
        let statements = SQLStatementScanner.executableStatements(in: script, grammar: TestGrammar.oracle)
        #expect(statements.map(\.acceptsBindParameters) == [false, true, true])
        let source = SQLParameterExtractor.parameterSource(of: statements)
        #expect(SQLParameterExtractor.extractParameters(from: source) == ["id", "a"])
    }

    @Test("Other dialects keep splitting a bare BEGIN at every semicolon", arguments: [
        TestGrammar.postgres, TestGrammar.mysql, TestGrammar.sqlite, TestGrammar.standard,
    ])
    func otherDialectsAreUnchanged(grammar: SQLLexicalGrammar) {
        let statements = SQLStatementScanner.allStatements(in: "BEGIN\nDROP TABLE users;\nSELECT 1;", grammar: grammar)
        #expect(statements == ["BEGIN\nDROP TABLE users", "SELECT 1"])
    }

    @Test("A slash line is only a terminator on Oracle")
    func slashLineIsOracleOnly() {
        let script = "SELECT 10\n/\n2 AS v FROM dual;"
        #expect(SQLStatementScanner.allStatements(in: script, grammar: TestGrammar.oracle) == ["SELECT 10", "2 AS v FROM dual"])
        #expect(SQLStatementScanner.allStatements(in: script, grammar: TestGrammar.standard) == ["SELECT 10\n/\n2 AS v FROM dual"])
    }

    @Test("An unterminated block takes the rest of the script with it")
    func unterminatedBlockTakesTheRest() {
        let statements = SQLStatementScanner.allStatements(in: "BEGIN\n  NULL;\nSELECT 1 FROM dual;", grammar: TestGrammar.oracle)
        #expect(statements == ["BEGIN\n  NULL;\nSELECT 1 FROM dual;"])
    }

    @Test("A script sent whole keeps the terminator its last unit needs")
    func executableTextKeepsTheUnitTerminator() {
        #expect(SQLStatementScanner.executableText(of: "BEGIN NULL; END;\n/\n", grammar: TestGrammar.oracle) == "BEGIN NULL; END;")
        #expect(SQLStatementScanner.executableText(of: "SELECT 1 FROM dual; ;", grammar: TestGrammar.oracle) == "SELECT 1 FROM dual")
        #expect(SQLStatementScanner.executableText(of: "/\n", grammar: TestGrammar.oracle).isEmpty)
    }

    @Test("A caret on a slash line runs the statement the slash ends")
    func caretOnSlashLineRunsTheStatementAbove() {
        let script = "BEGIN NULL; END;\n/\nSELECT 1 FROM dual\n/\n"
        let slashes = (0..<(script as NSString).length).filter { (script as NSString).character(at: $0) == 0x2F }
        #expect(slashes.count == 2)
        let afterSlashes = slashes.map { $0 + 1 }
        #expect(afterSlashes.map { SQLStatementScanner.statementAtCursor(in: script, cursorPosition: $0, grammar: TestGrammar.oracle) }
            == ["BEGIN NULL; END;", "SELECT 1 FROM dual"])
    }
}
