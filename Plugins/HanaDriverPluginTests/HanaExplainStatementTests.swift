import Foundation
import XCTest

final class HanaExplainStatementTests: XCTestCase {
    func testTheAppBuiltPrefixIsRecognised() {
        XCTAssertEqual(
            HanaExplainStatement.explainedStatement(in: "EXPLAIN PLAN FOR SELECT * FROM \"APP\".\"T\""),
            "SELECT * FROM \"APP\".\"T\""
        )
    }

    func testCaseWhitespaceAndCommentsAroundTheKeywordsAreAccepted() {
        XCTAssertEqual(HanaExplainStatement.explainedStatement(in: "explain plan for select 1 from dummy"), "select 1 from dummy")
        XCTAssertEqual(
            HanaExplainStatement.explainedStatement(in: "  \n\t-- why\nExplain\n  Plan\tFor\n  SELECT 1 FROM DUMMY"),
            "SELECT 1 FROM DUMMY"
        )
        XCTAssertEqual(
            HanaExplainStatement.explainedStatement(in: "/* plan */ EXPLAIN/**/PLAN /* x */ FOR SELECT 1 FROM DUMMY"),
            "SELECT 1 FROM DUMMY"
        )
        XCTAssertEqual(
            HanaExplainStatement.explainedStatement(in: "EXPLAIN PLAN FOR(SELECT 1 FROM DUMMY)"),
            "(SELECT 1 FROM DUMMY)"
        )
    }

    func testTrailingTerminatorsAreDropped() {
        XCTAssertEqual(
            HanaExplainStatement.explainedStatement(in: "EXPLAIN PLAN FOR UPDATE T SET A = 1;  \n"),
            "UPDATE T SET A = 1"
        )
    }

    func testOtherStatementsAreLeftAlone() {
        let statements = [
            "SELECT 'EXPLAIN PLAN FOR SELECT 1' FROM DUMMY",
            "EXPLAIN PLAN SET STATEMENT_NAME = 'x' FOR SELECT 1 FROM DUMMY",
            "EXPLAINPLAN FOR SELECT 1 FROM DUMMY",
            "EXPLAIN PLANS FOR SELECT 1 FROM DUMMY",
            "EXPLAIN PLAN FORX SELECT 1",
            "EXPLAIN PLAN FOR",
            "EXPLAIN PLAN FOR ;",
            "EXPLAIN PLAN",
            "-- EXPLAIN PLAN FOR SELECT 1",
            "/* EXPLAIN PLAN FOR SELECT 1",
            "",
            "   "
        ]
        for statement in statements {
            XCTAssertNil(HanaExplainStatement.explainedStatement(in: statement), statement)
        }
    }
}
