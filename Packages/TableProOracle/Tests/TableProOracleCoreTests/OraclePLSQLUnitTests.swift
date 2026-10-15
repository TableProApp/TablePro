import Foundation
@testable import TableProOracleCore
import Testing

/// Oracle stores a unit that does not compile and reports success, so the plugin reads the unit's errors back by the
/// owner, name and type the `CREATE` header names. Reading the wrong name reports a broken unit as fine.
struct OraclePLSQLUnitTests {
    @Test func testReadsTheUnitEachHeaderDefines() {
        let cases: [(sql: String, unit: OraclePLSQLUnit)] = [
            ("CREATE PROCEDURE p IS BEGIN NULL; END;", OraclePLSQLUnit(type: "PROCEDURE", owner: nil, name: "P")),
            (
                "create or replace editionable function hr.f return number is begin return 1; end;",
                OraclePLSQLUnit(type: "FUNCTION", owner: "HR", name: "F")
            ),
            ("CREATE OR REPLACE PACKAGE BODY pkg AS END;", OraclePLSQLUnit(type: "PACKAGE BODY", owner: nil, name: "PKG")),
            ("CREATE PACKAGE pkg AS END;", OraclePLSQLUnit(type: "PACKAGE", owner: nil, name: "PKG")),
            ("CREATE TYPE BODY t AS END;", OraclePLSQLUnit(type: "TYPE BODY", owner: nil, name: "T")),
            ("CREATE TYPE t AS OBJECT (a NUMBER);", OraclePLSQLUnit(type: "TYPE", owner: nil, name: "T")),
            (
                "-- note\nCREATE OR REPLACE TRIGGER \"App\".\"Audit\" BEFORE INSERT ON x FOR EACH ROW BEGIN NULL; END;",
                OraclePLSQLUnit(type: "TRIGGER", owner: "App", name: "Audit")
            ),
            (
                "CREATE PROCEDURE IF NOT EXISTS p IS BEGIN NULL; END;",
                OraclePLSQLUnit(type: "PROCEDURE", owner: nil, name: "P")
            ),
            ("CREATE NONEDITIONABLE PROCEDURE x$y#z IS BEGIN NULL; END;", OraclePLSQLUnit(type: "PROCEDURE", owner: nil, name: "X$Y#Z")),
        ]
        for example in cases {
            #expect(OraclePLSQLUnit.definition(in: example.sql) == example.unit, "\(example.sql)")
        }
    }

    @Test func testStatementsThatDefineNoUnit() {
        for sql in [
            "CREATE TABLE t (a NUMBER)",
            "CREATE OR REPLACE VIEW v AS SELECT 1 FROM dual",
            "BEGIN NULL; END;",
            "DROP PROCEDURE p",
            "SELECT 'CREATE PROCEDURE p' FROM dual",
        ] {
            #expect(OraclePLSQLUnit.definition(in: sql) == nil, "\(sql)")
        }
    }

    @Test func testErrorsQueryEscapesAndFallsBackToTheSessionSchema() {
        let named = OraclePLSQLUnit(type: "PACKAGE BODY", owner: "O'NEIL", name: "IT'S")
        #expect(named.errorsQuery.contains("OWNER = 'O''NEIL'"))
        #expect(named.errorsQuery.contains("NAME = 'IT''S'"))
        #expect(named.errorsQuery.contains("TYPE = 'PACKAGE BODY'"))
        #expect(named.errorsQuery.contains("ATTRIBUTE = 'ERROR'"))

        let unqualified = OraclePLSQLUnit(type: "PROCEDURE", owner: nil, name: "P")
        #expect(unqualified.errorsQuery.contains("OWNER = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')"))
    }

    @Test func testFailureMessageListsEveryError() {
        let unit = OraclePLSQLUnit(type: "PROCEDURE", owner: nil, name: "P")
        let message = unit.compilationFailureMessage(errors: [
            OracleCompilationError(line: 5, position: 3, text: "PLS-00103: Encountered the symbol \"end-of-file\"\n"),
            OracleCompilationError(line: 7, position: 1, text: "PL/SQL: Statement ignored"),
        ])
        #expect(message == """
            PROCEDURE P was created with compilation errors:
            Line 5, column 3: PLS-00103: Encountered the symbol "end-of-file"
            Line 7, column 1: PL/SQL: Statement ignored
            """)
    }

    @Test func testCompilationErrorReadsAnErrorsRow() {
        let error = OracleCompilationError(row: [.string("5"), .string("3"), .string("PLS-00103: x")])
        #expect(error == OracleCompilationError(line: 5, position: 3, text: "PLS-00103: x"))
        #expect(OracleCompilationError(row: [.null, .string("3"), .string("x")]) == nil)
    }

    @Test func testAnonymousBlocksAreRecognisedPastLabelsAndComments() {
        #expect(OraclePLSQLUnit.isAnonymousBlock("BEGIN NULL; END;"))
        #expect(OraclePLSQLUnit.isAnonymousBlock("declare v number; begin null; end;"))
        #expect(OraclePLSQLUnit.isAnonymousBlock("-- c\n<<outer>>\n<<inner>> BEGIN NULL; END;"))
        #expect(!OraclePLSQLUnit.isAnonymousBlock("SELECT 1 FROM dual"))
        #expect(!(OraclePLSQLUnit.isAnonymousBlock("CALL p()")))
    }
}
