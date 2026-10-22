import Foundation
@testable import TableProOracleCore
import Testing

struct OracleExplainPlanTests {
    @Test("A statement id fits PLAN_TABLE's VARCHAR2(30) and is never reused")
    func statementIdFits() {
        let first = OracleExplainPlan.statementId()
        let second = OracleExplainPlan.statementId()
        #expect(first.count == 30)
        #expect(first.hasPrefix("TP"))
        #expect(first != second)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber })
    }

    @Test("EXPLAIN PLAN takes the statement without its terminator, under the run's own statement id")
    func explainStatementDropsTerminator() {
        let statement = OracleExplainPlan.explainStatement("SELECT * FROM t ;\n", statementId: "TP1")
        #expect(statement == "EXPLAIN PLAN SET STATEMENT_ID = 'TP1' FOR SELECT * FROM t")
    }

    @Test("The plan rows are read and deleted by the run's statement id only")
    func readsAndDeletesOwnRows() {
        #expect(OracleExplainPlan.planRowsQuery(statementId: "TP1").contains("WHERE STATEMENT_ID = 'TP1'"))
        #expect(OracleExplainPlan.deleteStatement(statementId: "TP1") == "DELETE FROM PLAN_TABLE WHERE STATEMENT_ID = 'TP1'")
    }

    @Test("Only Oracle's three statistics levels are ever put back", arguments: [
        ("typical", "ALTER SESSION SET STATISTICS_LEVEL = TYPICAL"),
        (" ALL ", "ALTER SESSION SET STATISTICS_LEVEL = ALL"),
        ("BASIC", "ALTER SESSION SET STATISTICS_LEVEL = BASIC"),
    ])
    func restoresKnownLevels(level: String, statement: String) {
        #expect(OracleExplainPlan.setStatisticsLevel(level) == statement)
    }

    @Test("A level that is not one of Oracle's is never spliced into a statement", arguments: ["", "ALL; DROP TABLE t", "FULL"])
    func refusesUnknownLevels(level: String) {
        #expect(OracleExplainPlan.setStatisticsLevel(level) == nil)
    }

    @Test("The actual plan reads the cursor the session ran last")
    func actualPlanReadsPreviousCursor() {
        let query = OracleExplainPlan.lastCursorPlanQuery
        #expect(query.contains("p.SQL_ID = s.PREV_SQL_ID"))
        #expect(query.contains("p.CHILD_NUMBER = s.PREV_CHILD_NUMBER"))
        #expect(query.contains("p.LAST_STARTS"))
    }

    @Test("A view the account cannot see reads as a missing grant, and any other failure does not", arguments: [
        ("ORA-00942: table or view \"SYS\".\"V_$SESSION\" does not exist", true),
        ("ORA-01031: insufficient privileges", true),
        ("ORA-00904: invalid identifier", false),
    ])
    func classifiesMissingGrants(message: String, isMissingGrant: Bool) {
        #expect(OracleExplainPlan.isMissingGrant(OracleCoreError.queryFailed(message)) == isMissingGrant)
        #expect(!OracleExplainPlan.isMissingGrant(CancellationError()))
    }

    @Test("Plan rows become JSON objects keyed by column, numbers as numbers and NULL left out")
    func encodesDocument() throws {
        let result = OracleRawResult(
            columns: [
                OracleColumnDescriptor(name: "ID", typeName: "NUMBER"),
                OracleColumnDescriptor(name: "PARENT_ID", typeName: "NUMBER"),
                OracleColumnDescriptor(name: "OPERATION", typeName: "VARCHAR2"),
                OracleColumnDescriptor(name: "COST", typeName: "NUMBER"),
            ],
            rows: [
                [.string("0"), .null, .string("SELECT STATEMENT"), .string("2.5")],
                [.string("1"), .string("0"), .string("TABLE ACCESS"), .null],
            ],
            affectedRows: 2,
            isTruncated: false
        )
        let document = OracleExplainPlan.document(from: result)
        let rows = try #require(
            try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [[String: Any]]
        )

        #expect(rows.count == 2)
        #expect(rows[0]["ID"] as? Int == 0)
        #expect(rows[0]["PARENT_ID"] == nil)
        #expect(rows[0]["COST"] as? Double == 2.5)
        #expect(rows[1]["PARENT_ID"] as? Int == 0)
        #expect(rows[1]["OPERATION"] as? String == "TABLE ACCESS")
        #expect(rows[1]["COST"] == nil)
    }
}
