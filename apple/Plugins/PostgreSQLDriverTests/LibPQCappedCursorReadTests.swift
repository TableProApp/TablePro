//
//  LibPQCappedCursorReadTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import Testing

struct LibPQCappedCursorReadTests {
    @Test("Inside a transaction the cap plus one row are sent and the rest run on the server unsent")
    func insideTransactionFetchesCapPlusOne() throws {
        let plan = try #require(LibPQCappedCursorRead.plan(
            for: "SELECT * FROM events", rowCap: 1_000, scope: .insideTransaction
        ))

        #expect(plan.fetchCount == 1_001)
        #expect(plan.opening == "SAVEPOINT tablepro_capped_read")
        #expect(plan.statement == """
            DECLARE tablepro_capped_read NO SCROLL CURSOR FOR
            SELECT * FROM events
            ;
            FETCH FORWARD 1001 FROM tablepro_capped_read;
            MOVE FORWARD ALL FROM tablepro_capped_read;
            CLOSE tablepro_capped_read;
            RELEASE SAVEPOINT tablepro_capped_read
            """)
        #expect(plan.recovery == "ROLLBACK TO SAVEPOINT tablepro_capped_read; RELEASE SAVEPOINT tablepro_capped_read")
    }

    @Test("Outside a transaction the cursor gets a transaction of its own")
    func ownTransactionOpensAndCommits() throws {
        let plan = try #require(LibPQCappedCursorRead.plan(for: "VALUES (1)", rowCap: 10, scope: .ownTransaction))

        #expect(plan.opening == "BEGIN")
        #expect(plan.statement.hasPrefix("DECLARE tablepro_capped_read NO SCROLL CURSOR FOR\nVALUES (1)\n;"))
        #expect(plan.statement.hasSuffix(
            "FETCH FORWARD 11 FROM tablepro_capped_read;\nMOVE FORWARD ALL FROM tablepro_capped_read;\nCLOSE tablepro_capped_read;\nCOMMIT"
        ))
        #expect(plan.recovery == "ROLLBACK")
    }

    @Test("A trailing line comment ends before the FETCH")
    func trailingLineCommentKeepsTheFetch() throws {
        let plan = try #require(LibPQCappedCursorRead.plan(
            for: "SELECT 1 -- tail", rowCap: 5, scope: .insideTransaction
        ))

        #expect(plan.statement.contains("SELECT 1 -- tail\n;\nFETCH FORWARD 6"))
    }

    @Test(
        "One read statement goes through the cursor",
        arguments: [
            ("SELECT * FROM t;  \n", "SELECT * FROM t"),
            ("select a from t;;", "select a from t"),
            ("-- note\n(SELECT 1) UNION (SELECT 2)", "-- note\n(SELECT 1) UNION (SELECT 2)"),
            ("/* c */ WITH x AS (SELECT 1) SELECT * FROM x", "/* c */ WITH x AS (SELECT 1) SELECT * FROM x"),
            ("TABLE accounts", "TABLE accounts"),
            ("SELECT updated_at, shared_by FROM t", "SELECT updated_at, shared_by FROM t"),
        ]
    )
    func readStatementIsCursorable(query: String, body: String) {
        #expect(LibPQCappedCursorRead.cursorBody(of: query) == body)
    }

    @Test(
        "A statement a cursor would change or refuse runs the plain way",
        arguments: [
            "SELECT 1; SELECT 2",
            "SELECT ';' AS semicolon",
            "SELECT * FROM t FOR UPDATE",
            "SELECT * FROM t FOR NO KEY UPDATE SKIP LOCKED",
            "SELECT * FROM t FOR KEY SHARE",
            "SELECT * INTO copy FROM t",
            "WITH gone AS (DELETE FROM t RETURNING *) SELECT * FROM gone",
            "INSERT INTO t VALUES (1) RETURNING *",
            "EXPLAIN SELECT 1",
            "SHOW search_path",
            "/* unterminated SELECT 1",
            "",
            "  ;  ",
        ]
    )
    func otherStatementsAreNotCursorable(query: String) {
        #expect(LibPQCappedCursorRead.cursorBody(of: query) == nil)
    }

    @Test("A cap FETCH cannot spell runs the plain way", arguments: [0, -1, Int(Int32.max)])
    func capOutsideFetchRangeHasNoPlan(rowCap: Int) {
        #expect(LibPQCappedCursorRead.plan(for: "SELECT 1", rowCap: rowCap, scope: .insideTransaction) == nil)
    }
}
