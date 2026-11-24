import Foundation
import TableProOracleCore
import Testing

struct OracleRoutineStatementsTests {
    @Test func dropsAProcedureInTheCurrentSchemaByItsBareName() {
        let sql = OracleRoutineStatements.drop(name: "P_SYNC", schema: "APP", currentSchema: "APP", isFunction: false)

        #expect(sql == """
            BEGIN
              EXECUTE IMMEDIATE 'DROP PROCEDURE "P_SYNC"';
            EXCEPTION
              WHEN OTHERS THEN
                IF SQLCODE != -4043 THEN
                  RAISE;
                END IF;
            END;
            """)
    }

    @Test func dropsAFunctionWithTheFunctionKeyword() {
        let sql = OracleRoutineStatements.drop(name: "F_TOTAL", schema: nil, currentSchema: "APP", isFunction: true)

        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP FUNCTION \"F_TOTAL\"';"))
        #expect(!sql.contains("PROCEDURE"))
    }

    @Test func qualifiesARoutineAnotherSchemaOwns() {
        let sql = OracleRoutineStatements.drop(name: "P_SYNC", schema: "HR", currentSchema: "APP", isFunction: false)

        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP PROCEDURE \"HR\".\"P_SYNC\"';"))
    }

    @Test func anEmptySchemaMeansTheCurrentOne() {
        let sql = OracleRoutineStatements.drop(name: "P_SYNC", schema: "  ", currentSchema: "APP", isFunction: false)

        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP PROCEDURE \"P_SYNC\"';"))
    }

    @Test func aQuoteInTheNameIsDoubledInsideTheLiteral() {
        let sql = OracleRoutineStatements.drop(name: "it's", schema: nil, currentSchema: nil, isFunction: true)

        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP FUNCTION \"it''s\"';"))
    }

    @Test func onlyAMissingObjectIsIgnored() {
        let sql = OracleRoutineStatements.drop(name: "P", schema: nil, currentSchema: nil, isFunction: false)

        #expect(sql.contains("IF SQLCODE != -4043 THEN"))
        #expect(sql.contains("RAISE;"))
        #expect(sql.hasSuffix("END;"))
    }
}
