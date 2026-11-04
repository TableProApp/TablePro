//
//  MySQLTemporaryTableNamesTests.swift
//  TableProTests
//

import Foundation
import TableProMySQLCore
import TableProPluginKit
import Testing

struct MySQLTemporaryTableNamesTests {
    private func names(after statements: String...) -> [String] {
        var footprint = MySQLSessionFootprint()
        for statement in statements {
            footprint.observe(statement, lexicalFeatures: MySQLLexicalFeatures.mySQL)
        }
        return footprint.temporaryTableNames
    }

    @Test("Every spelling of CREATE TEMPORARY TABLE names the table it creates")
    func createSpellings() {
        #expect(names(after: "CREATE TEMPORARY TABLE t AS SELECT 1 AS x") == ["t"])
        #expect(names(after: "create temporary table IF NOT EXISTS `my t` (a int)") == ["my t"])
        #expect(names(after: "CREATE OR REPLACE TEMPORARY TABLE shop.`odd``name` (a INT)") == ["odd`name"])
        #expect(names(after: "CREATE TEMPORARY\n  TABLE /* note */ staging LIKE orders") == ["staging"])
        #expect(names(after: "CREATE TEMPORARY --\u{7F}note\n TABLE noted (a INT)") == ["noted"])
        #expect(names(after: "/*!40101 CREATE TEMPORARY TABLE dumped (a INT) */") == ["dumped"])
        #expect(names(after: "CREATE /*!32312 TEMPORARY */ TABLE inline (a INT)") == ["inline"])
        #expect(names(after: "CREATE /*M!100100 TEMPORARY */ TABLE maria (a INT)") == ["maria"])
    }

    @Test("A temporary table created inside an executable comment blocks the release too")
    func inlineExecutableCommentBlocksRelease() {
        var footprint = MySQLSessionFootprint()
        footprint.observe("CREATE /*!32312 TEMPORARY */ TABLE inline (a INT)", lexicalFeatures: MySQLLexicalFeatures.mySQL)
        #expect(footprint.hasTemporaryTables)
        #expect(footprint.blockingReason != nil)
    }

    @Test("A statement that creates no temporary table names nothing")
    func otherStatementsNameNothing() {
        #expect(names(
            after: "CREATE TABLE t (a INT)",
            "SELECT 'CREATE TEMPORARY TABLE x'",
            "INSERT INTO t VALUES (1)",
            "CREATE TEMPORARY TABLE"
        ).isEmpty)
    }

    @Test("A rename of a known temporary table adds the new name")
    func renamesFollowKnownNames() {
        #expect(names(after: "CREATE TEMPORARY TABLE a (x INT)", "RENAME TABLE a TO b, other TO c") == ["a", "b"])
        #expect(names(after: "CREATE TEMPORARY TABLE a (x INT)", "ALTER TABLE a RENAME TO b") == ["a", "b"])
        #expect(names(after: "CREATE TEMPORARY TABLE a (x INT)", "ALTER TABLE a ADD y INT, RENAME AS `b`") == ["a", "b"])
        #expect(names(after: "CREATE TEMPORARY TABLE a (x INT)", "ALTER TABLE a RENAME COLUMN x TO y") == ["a"])
        #expect(names(after: "RENAME TABLE base TO other").isEmpty)
    }

    @Test("A name is kept once however often it is created")
    func namesAreKeptOnce() {
        #expect(names(after: "CREATE TEMPORARY TABLE t (a INT)", "DROP TEMPORARY TABLE t", "CREATE TEMPORARY TABLE t (a INT)") == ["t"])
    }

    @Test("A reconnect forgets every name")
    func resetForgetsNames() {
        var footprint = MySQLSessionFootprint()
        footprint.observe("CREATE TEMPORARY TABLE t (a INT)", lexicalFeatures: MySQLLexicalFeatures.mySQL)
        footprint.reset()
        #expect(footprint.temporaryTableNames.isEmpty)
    }

    @Test("SHOW CREATE TABLE answers CREATE TEMPORARY TABLE only for a temporary table")
    func declaresTemporaryTable() {
        #expect(MySQLTemporaryTableNames.declaresTemporaryTable("CREATE TEMPORARY TABLE `t` (\n  `x` int\n)"))
        #expect(!MySQLTemporaryTableNames.declaresTemporaryTable("CREATE TABLE `t` (\n  `x` int\n)"))
    }
}
