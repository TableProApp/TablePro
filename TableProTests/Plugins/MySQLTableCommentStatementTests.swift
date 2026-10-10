//
//  MySQLTableCommentStatementTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MySQLTableCommentStatementTests {
    @Test("A table and a partitioned table take ALTER TABLE ... COMMENT", arguments: ["TABLE", "PARTITIONED TABLE", "table"])
    func tableKindsTakeAComment(objectType: String) {
        #expect(MySQLObjectQueries.tableCommentStatement(
            qualifiedTable: "`s`.`t`", objectType: objectType, comment: "Orders"
        ) == "ALTER TABLE `s`.`t` COMMENT = 'Orders'")
    }

    @Test("Kinds with no COMMENT clause produce no statement", arguments: [
        "VIEW", "MATERIALIZED VIEW", "SYSTEM TABLE", "EXTERNAL TABLE", "SEQUENCE", "FOREIGN TABLE", ""
    ])
    func otherKindsProduceNoStatement(objectType: String) {
        #expect(!MySQLObjectQueries.takesTableComment(objectType: objectType))
        #expect(MySQLObjectQueries.tableCommentStatement(
            qualifiedTable: "`t`", objectType: objectType, comment: "x"
        ) == nil)
        #expect(DatabendCatalog.tableCommentStatement(
            qualifiedTable: "`t`", objectType: objectType, comment: "x"
        ) == nil)
    }

    @Test("A nil or empty comment clears it with an empty literal", arguments: [nil, ""] as [String?])
    func emptyCommentClears(comment: String?) {
        #expect(MySQLObjectQueries.tableCommentStatement(
            qualifiedTable: "`t`", objectType: "TABLE", comment: comment
        ) == "ALTER TABLE `t` COMMENT = ''")
    }

    @Test("Quotes, backslashes and line breaks are escaped")
    func specialCharactersAreEscaped() {
        let sql = MySQLObjectQueries.tableCommentStatement(
            qualifiedTable: "`t`", objectType: "TABLE", comment: "it's C:\\temp\nnext"
        )
        #expect(sql == #"ALTER TABLE `t` COMMENT = 'it''s C:\\temp\nnext'"#)
    }

    @Test("A NO_BACKSLASH_ESCAPES session gets the same comment back after respelling")
    func respelledStatementKeepsTheComment() throws {
        let sql = try #require(MySQLObjectQueries.tableCommentStatement(
            qualifiedTable: "`t`", objectType: "TABLE", comment: "it's C:\\temp\nnext"
        ))
        #expect(MySQLLiteralSpelling.quoteDoubling.respelled(sql)
            == "ALTER TABLE `t` COMMENT = 'it''s C:\\temp\nnext'")
        #expect(MySQLLiteralSpelling.backslashEscapes.respelled(sql) == sql)
    }

    @Test("The table is qualified only when a database is named")
    func qualificationFollowsTheSchema() {
        #expect(MySQLObjectQueries.qualifiedIdentifier(schema: "shop", name: "or`ders") == "`shop`.`or``ders`")
        #expect(MySQLObjectQueries.qualifiedIdentifier(schema: nil, name: "orders") == "`orders`")
    }

    @Test("Databend escapes the comment with its own literal rules")
    func databendStatement() {
        #expect(DatabendCatalog.tableCommentStatement(
            qualifiedTable: "`t`", objectType: "TABLE", comment: "it's\u{0C}x"
        ) == #"ALTER TABLE `t` COMMENT = 'it''s\fx'"#)
        #expect(DatabendCatalog.tableCommentStatement(
            qualifiedTable: "`t`", objectType: "TABLE", comment: nil
        ) == "ALTER TABLE `t` COMMENT = ''")
    }

    @Test("An apostrophe followed by a combining mark is still doubled")
    func apostropheBeforeCombiningMark() {
        let statement = MySQLObjectQueries.tableCommentStatement(
            qualifiedTable: "`t`", objectType: "TABLE", comment: "a'\u{0301}b"
        )
        #expect(statement == "ALTER TABLE `t` COMMENT = 'a''\u{0301}b'")
    }
}
