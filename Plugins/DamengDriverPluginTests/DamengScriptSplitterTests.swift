import Foundation
import XCTest

/// DM8 rejects a string holding more than one statement, so the driver has to find the
/// boundaries itself. Getting a boundary wrong sends the server half a statement.
final class DamengScriptSplitterTests: XCTestCase {
    func testASingleStatementIsReturnedWhole() {
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT 1 FROM DUAL"),
            ["SELECT 1 FROM DUAL"]
        )
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "  SELECT 1 FROM DUAL;\n"),
            ["SELECT 1 FROM DUAL"]
        )
        XCTAssertEqual(DamengScriptSplitter.statements(in: "   \n  "), [])
    }

    func testGeneratedTableDDLSplitsIntoItsStatements() {
        let script = """
            CREATE TABLE "APP"."order" (
                "id" INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                "note" VARCHAR(100)
            );
            CREATE INDEX "idx note" ON "APP"."order" ("note");
            COMMENT ON COLUMN "APP"."order"."note" IS 'a note';
            """
        let statements = DamengScriptSplitter.statements(in: script)

        XCTAssertEqual(statements.count, 3)
        XCTAssertTrue(statements[0].hasPrefix("CREATE TABLE"))
        XCTAssertTrue(statements[1].hasPrefix("CREATE INDEX"))
        XCTAssertTrue(statements[2].hasPrefix("COMMENT ON COLUMN"))
        XCTAssertFalse(statements.contains { $0.hasSuffix(";") })
    }

    /// Pairing BEGIN/CASE/IF/LOOP against END, END IF, END LOOP and END CASE is more structure
    /// than a driver should guess at, and guessing wrong cuts a block in half. A script holding
    /// any of them is passed through whole instead, which is what happened before the splitter.
    func testAnyBlockKeywordAbandonsTheSplit() {
        let block = "BEGIN EXECUTE IMMEDIATE 'SET SCHEMA \"APP\"'; END;"
        XCTAssertEqual(DamengScriptSplitter.statements(in: block), [block])

        for script in [
            "BEGIN IF 1 = 1 THEN NULL; END IF; END;",
            "DECLARE n INT; BEGIN n := 1; END;",
            "BEGIN FOR r IN (SELECT 1 FROM DUAL) LOOP NULL; END LOOP; END;",
            "SELECT CASE WHEN 1 = 1 THEN 'y' END FROM DUAL; SELECT 2 FROM DUAL"
        ] {
            XCTAssertEqual(DamengScriptSplitter.statements(in: script), [script], script)
        }
    }

    /// A block keyword inside a literal or an identifier is not a block.
    func testABlockKeywordInsideALiteralStillSplits() {
        let script = "INSERT INTO t VALUES('BEGIN');\nSELECT 1 FROM DUAL"
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: script),
            ["INSERT INTO t VALUES('BEGIN')", "SELECT 1 FROM DUAL"]
        )
    }

    /// `q'{...}'` holds an apostrophe without ending the literal, so a naive scan would treat
    /// the semicolon after it as a boundary and cut the statement in half.
    func testAlternativeQuotingHidesItsApostrophesAndSemicolons() {
        let script = "INSERT INTO t VALUES(q'{it's ok; really}');\nSELECT 1 FROM DUAL"
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: script),
            ["INSERT INTO t VALUES(q'{it's ok; really}')", "SELECT 1 FROM DUAL"]
        )
    }

    func testABackslashEscapedQuoteDoesNotEndTheLiteral() {
        let script = "SELECT 'a\\'; b' FROM DUAL;\nSELECT 2 FROM DUAL"
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: script, escaping: .backslashEscape),
            ["SELECT 'a\\'; b' FROM DUAL", "SELECT 2 FROM DUAL"]
        )
    }

    /// A trailing comment is not a statement. Sending one to DM8 fails the script after its
    /// real work has already run and cannot be undone.
    func testACommentOnlySegmentIsNotAStatement() {
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT 1 FROM DUAL;\n-- done"),
            ["SELECT 1 FROM DUAL"]
        )
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT 1 FROM DUAL;\n/* done */\n"),
            ["SELECT 1 FROM DUAL"]
        )
    }

    func testASemicolonInsideALiteralOrIdentifierIsNotABoundary() {
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "INSERT INTO t VALUES('a;b')"),
            ["INSERT INTO t VALUES('a;b')"]
        )
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "INSERT INTO t VALUES('it''s; fine')"),
            ["INSERT INTO t VALUES('it''s; fine')"]
        )
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT \"a;b\" FROM t"),
            ["SELECT \"a;b\" FROM t"]
        )
    }

    func testASemicolonInsideACommentIsNotABoundary() {
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT 1 -- one; two\nFROM DUAL"),
            ["SELECT 1 -- one; two\nFROM DUAL"]
        )
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT /* one; /* two; */ */ 1 FROM DUAL"),
            ["SELECT /* one; /* two; */ */ 1 FROM DUAL"]
        )
    }

    func testEmptyStatementsBetweenTerminatorsAreDropped() {
        XCTAssertEqual(
            DamengScriptSplitter.statements(in: "SELECT 1 FROM DUAL;;\n;SELECT 2 FROM DUAL;"),
            ["SELECT 1 FROM DUAL", "SELECT 2 FROM DUAL"]
        )
    }
}
