import Foundation
import TableProSQLGrammar
import Testing

@Suite("The END of a CASE expression")
struct SQLCaseExpressionEndTests {
    private func sent(_ sql: String, _ typeId: String) -> [String] {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        return SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    @Test(
        "A label or a clause after it does not keep the CASE open",
        arguments: [
            "CREATE VIEW v AS SELECT CASE WHEN a THEN 1 END loop FROM t",
            "CREATE VIEW v AS SELECT CASE WHEN a THEN 1 END if FROM t",
            "CREATE VIEW v AS SELECT CASE WHEN a THEN 1 END while FROM t",
            "CREATE VIEW v AS SELECT CASE WHEN a THEN 1 END repeat FROM t",
            "CREATE VIEW v AS SELECT CASE WHEN CASE WHEN a THEN 1 END THEN 1 END /* label */ loop FROM t",
            "CREATE TABLE n AS SELECT substring(a FROM CASE WHEN b THEN 1 END FOR 2) FROM t",
            "DECLARE c CURSOR FOR SELECT CASE WHEN a THEN 1 END FOR UPDATE",
        ]
    )
    func wordAfterTheEnd(create: String) {
        #expect(sent(create + "; DROP TABLE users", "PostgreSQL") == [create, "DROP TABLE users"])
    }

    @Test("END IF, END LOOP and END REPEAT inside a CASE statement still close their own construct")
    func controlFlowInsideACaseStatement() {
        let routine = """
            CREATE PROCEDURE p(x INT)
            BEGIN
              CASE x
                WHEN 1 THEN IF x THEN SELECT 1; END IF;
                WHEN 2 THEN l: LOOP LEAVE l; END LOOP;
                WHEN 3 THEN IF x THEN BEGIN END; END IF;
                ELSE REPEAT SET x = x + 1; UNTIL CASE WHEN x > 5 THEN 1 END END REPEAT;
              END CASE;
              WHILE CASE WHEN x THEN 1 END DO SET x = 0; END WHILE;
            END
            """
        #expect(sent(routine + ";\nSELECT 2", "MySQL") == [routine, "SELECT 2"])
    }

    @Test("A query inside a routine body that ends in CASE ... END FOR UPDATE leaves the body balanced")
    func lockingClauseInsideARoutineBody() {
        let routine = """
            CREATE PROCEDURE p(x INT)
            BEGIN
              SELECT a FROM t WHERE b = CASE WHEN x THEN 1 ELSE 2 END FOR UPDATE;
              IF x THEN SELECT 1; END IF;
            END
            """
        #expect(sent(routine + ";\nSELECT 2", "MySQL") == [routine, "SELECT 2"])
    }

    @Test("A PL/SQL loop bound or a locking clause after it does not keep the unit open")
    func wordAfterTheEndInPLSQL() {
        let block = """
            BEGIN
              FOR i IN 1..CASE WHEN a THEN 1 ELSE 2 END LOOP
                CASE i WHEN 1 THEN IF a THEN NULL; END IF; ELSE NULL; END CASE;
              END LOOP;
              SELECT a INTO v FROM t WHERE b = CASE WHEN c = 1 THEN 1 END FOR UPDATE;
            END;
            """
        #expect(sent(block + "\nDROP TABLE users;", "Oracle") == [block, "DROP TABLE users"])
    }
}
