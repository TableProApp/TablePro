//
//  MySQLDatabaseMoveScanTests.swift
//  TableProTests
//

import Foundation
import TableProMySQLCore
import TableProPluginKit
import Testing

struct MySQLDatabaseMoveScanTests {
    private func footprint(after statements: String...) -> MySQLSessionFootprint {
        var footprint = MySQLSessionFootprint()
        for statement in statements {
            footprint.observe(statement, lexicalFeatures: MySQLLexicalFeatures.mySQL)
        }
        return footprint
    }

    @Test("Every spelling of USE the server accepts is seen", arguments: [
        "USE other",
        "use other",
        "USE`other`",
        "USE/* note */other",
        "USE\n`other`",
        "/* note */ USE other",
        "-- note\nUSE other",
        "# note\nUSE other",
        "/*!40000 USE other */",
        "/*! USE other */",
        "/*M!100000 USE other */",
        "/*!40101 */ /*!40101 USE other */",
        "/*!99999 x */ USE other",
        "/*!99999 '*/ USE other; -- ' */",
    ])
    func everySpellingOfUseIsSeen(sql: String) {
        let move = MySQLDatabaseMoveScan.move(of: sql)
        #expect(move.changesDatabase)
        #expect(!move.staysOnDatabase)
        #expect(footprint(after: sql).hasChangedDatabase)
        #expect(!mysqlMayReplay("SELECT 1", on: footprint(after: sql)))
    }

    @Test("A word that only starts like USE is not a USE", arguments: [
        "USER_DEFINED_THING",
        "USE_ME",
        "SELECT * FROM t USE INDEX (i)",
        "uſe other",
        "'USE other'",
        "/* USE other */ SELECT 1",
        "-- USE other\nSELECT 1",
    ])
    func otherWordsAreNotUse(sql: String) {
        #expect(!MySQLDatabaseMoveScan.move(of: sql).changesDatabase)
    }

    @Test("Code the scan cannot read through is opaque", arguments: [
        "EXECUTE IMMEDIATE 'USE other'",
        "execute/* note */immediate 'USE other'",
        "/*M!100200 EXECUTE IMMEDIATE 'USE other' */",
        "/*!40101 */ /*!40101 EXECUTE IMMEDIATE 'USE other' */",
        "CALL refresh()",
        "CALL`refresh`()",
        "CALL/* note */refresh()",
        "BEGIN NOT ATOMIC EXECUTE IMMEDIATE 'USE other'; END",
        "BEGIN/* note */NOT ATOMIC SELECT 1; END",
        "IF 1 THEN EXECUTE IMMEDIATE 'USE other'; END IF",
        "WHILE 1 DO SELECT 1; END WHILE",
        "/*!40101 -- */ USE other\n */",
        "/*M!100000 SELECT '/*' */ USE other",
        "/*!40101 /* note */ USE other */",
        "/*!40101 /*!99999 x */ USE other */",
    ])
    func opaqueCodeIsNotTrusted(sql: String) {
        let move = MySQLDatabaseMoveScan.move(of: sql)
        #expect(move.runsOpaqueCode)
        #expect(!move.staysOnDatabase)
        #expect(!mysqlMayReplay("SELECT 1", on: footprint(after: sql)))
    }

    @Test("A bare BEGIN opens a transaction, not a block")
    func bareBeginIsNotOpaque() {
        #expect(!MySQLDatabaseMoveScan.move(of: "BEGIN").runsOpaqueCode)
        #expect(!MySQLDatabaseMoveScan.move(of: "BEGIN WORK").runsOpaqueCode)
    }

    @Test("A dump's trigger body is not read as the statement")
    func dumpTriggerBodyIsLeftAlone() {
        let sql = "/*!50003 CREATE*/ /*!50017 DEFINER=`a`@`b`*/ /*!50003 TRIGGER t BEFORE INSERT ON x "
            + "FOR EACH ROW BEGIN CALL audit(); IF 1 THEN SET @a = 1; END IF; END */"
        let move = MySQLDatabaseMoveScan.move(of: sql)
        #expect(!move.changesDatabase)
        #expect(!move.runsOpaqueCode)
    }

    @Test("A read or a row write proves the session stayed", arguments: [
        "SELECT 1",
        "select * from t where id = 3;",
        "  /* note */ SELECT 1 ;  ",
        "-- note\nSELECT 1",
        "SELECT*FROM t",
        "INSERT INTO t VALUES (1)",
        "UPDATE t SET a = 1",
        "DELETE FROM t",
        "REPLACE INTO t VALUES (1)",
        "SHOW FULL COLUMNS FROM `t`",
        "DESCRIBE t",
        "DESC t",
        "EXPLAIN SELECT 1",
        "WITH c AS (SELECT 1) SELECT * FROM c",
        "VALUES ROW(1)",
        "TABLE t",
        "DO 0",
    ])
    func provenStatementsStay(sql: String) {
        #expect(MySQLDatabaseMoveScan.move(of: sql).staysOnDatabase)
    }

    @Test("Anything else proves nothing", arguments: [
        "",
        "   ",
        "/* only a note */",
        "SET @x = 1",
        "SET STATEMENT max_statement_time=0 FOR USE other",
        "START TRANSACTION",
        "COMMIT",
        "DROP DATABASE main",
        "DROP SCHEMA main",
        "CREATE TABLE t (a INT)",
        "HANDLER t OPEN",
        "SELECT 1; USE other",
        "; USE other",
        "SELECT 1 /*!40101 , 2 */",
        "SELECT /*M!100000 1, */ 2",
        "/*!40101 SELECT 1 */",
        "/*!99999 x */ SELECT 1",
        "--x\nSELECT 1",
        "SELECTED",
        "'SELECT'",
    ])
    func everythingElseProvesNothing(sql: String) {
        #expect(!MySQLDatabaseMoveScan.move(of: sql).staysOnDatabase)
    }

    @Test("Thousands of nested and empty comments are read in one pass")
    func commentChainsStayLinear() {
        let empty = String(repeating: "/*!50000 */ ", count: 40_000)
        #expect(MySQLDatabaseMoveScan.move(of: empty + "USE other").changesDatabase)
        let nested = String(repeating: "/*!50000 ", count: 40_000)
        #expect(MySQLDatabaseMoveScan.move(of: nested + "USE other").runsOpaqueCode)
        let long = "SELECT 1" + String(repeating: " ", count: 2_000_000)
        #expect(MySQLDatabaseMoveScan.move(of: long).staysOnDatabase)
    }

    @Test("A chain of version comments too long to read counts as opaque")
    func longCommentChainIsOpaque() {
        let chain = String(repeating: "/*!99999 SET @x = 1 */ ", count: 2_000)
        #expect(footprint(after: chain + "SELECT 1").ranOpaqueRoutine)
    }

    @Test("A statement behind an empty version comment still counts")
    func emptyCommentHidesNothing() {
        #expect(footprint(after: "/*!40101 */ /*!40101 SET @x = 1 */").hasUserVariables)
        #expect(footprint(after: "/*!40101 */ /*!40101 SET sql_mode = '' */").hasSessionSettings)
    }

    @Test("The proof holds only for the database the session entered")
    func proofNamesTheDatabase() {
        var proof = MySQLSessionDatabaseProof()
        #expect(!proof.proves("main"))
        proof.noteEntered("main")
        #expect(proof.proves("main"))
        #expect(!proof.proves("MAIN"))
        #expect(!proof.proves("other"))
        #expect(!proof.proves(""))
    }

    @Test("A composed and a decomposed accent are two databases")
    func proofComparesBytes() {
        var proof = MySQLSessionDatabaseProof()
        proof.noteEntered("caf\u{E9}")
        #expect(proof.proves("caf\u{E9}"))
        #expect(!proof.proves("cafe\u{301}"))
    }

    @Test("A proven statement keeps the proof")
    func provenStatementKeepsTheProof() {
        var proof = MySQLSessionDatabaseProof()
        proof.noteEntered("main")
        proof.observe("SELECT * FROM t")
        proof.observe("UPDATE t SET a = 1")
        #expect(proof.proves("main"))
    }

    @Test("A statement the scan cannot prove ends the proof", arguments: [
        "USE other",
        "USE`other`",
        "DROP DATABASE main",
        "EXECUTE IMMEDIATE 'USE other'",
        "/*!40101 */ /*!40101 USE other */",
        "CREATE TABLE t (a INT)",
    ])
    func unprovenStatementEndsTheProof(sql: String) {
        var proof = MySQLSessionDatabaseProof()
        proof.noteEntered("main")
        proof.observe(sql)
        #expect(!proof.proves("main"))
    }
}
