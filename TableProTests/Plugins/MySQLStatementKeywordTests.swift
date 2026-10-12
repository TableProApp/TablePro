//
//  MySQLStatementKeywordTests.swift
//  TableProTests
//

import Testing

struct MySQLStatementKeywordTests {
    /// Measured on 4.1.22 for `SHOW`, `DESCRIBE` and `HELP`; the maintenance statements build the same
    /// columns in 4.1.22's source.
    @Test("Statements whose text the server builds itself are recognized")
    func serverMetadataStatements() {
        for query in [
            "SHOW TABLES",
            "show full columns from apcust",
            "DESC apcust",
            "DESCRIBE apcust",
            "HELP 'contents'",
            "CHECK TABLE apcust",
            "ANALYZE TABLE apcust",
            "OPTIMIZE TABLE apcust",
            "REPAIR TABLE apcust",
            "CHECKSUM TABLE apcust",
            "EXPLAIN apcust",
        ] {
            #expect(mysqlStatementListsServerMetadata(query), "\(query)")
        }
    }

    @Test("A query, a write or nothing at all is not server metadata")
    func otherStatements() {
        for query in ["SELECT * FROM apcust", "select 1", "INSERT INTO apcust VALUES (1)", "SHOWX", "", "   "] {
            #expect(!mysqlStatementListsServerMetadata(query), "\(query)")
        }
    }

    @Test("Whitespace and comments before the statement are skipped")
    func leadingComments() {
        #expect(mysqlLeadingKeyword("  \n\tshow tables") == "SHOW")
        #expect(mysqlLeadingKeyword("/* c */ SHOW TABLES") == "SHOW")
        #expect(mysqlLeadingKeyword("-- c\nSHOW TABLES") == "SHOW")
        #expect(mysqlLeadingKeyword("#c\nSHOW TABLES") == "SHOW")
        #expect(mysqlLeadingKeyword("--\nSHOW TABLES") == "SHOW")
        #expect(mysqlLeadingKeyword("/* a */ # b\n -- c\n\tDESC apcust") == "DESC")
        #expect(mysqlStatementListsServerMetadata("/* c */ SHOW TABLES"))
    }

    /// MySQL starts a `--` comment only when whitespace follows the dashes.
    @Test("Two dashes with no whitespace after them are not a comment")
    func doubleDashNeedsWhitespace() {
        #expect(mysqlLeadingKeyword("--x\nSHOW TABLES") == "")
        #expect(!mysqlStatementListsServerMetadata("--x\nSHOW TABLES"))
    }

    @Test("An executable comment is the statement's own text, so it ends the scan")
    func executableCommentEndsTheScan() {
        #expect(mysqlLeadingKeyword("/*!40101 SET NAMES utf8 */") == "")
        #expect(!mysqlStatementListsServerMetadata("/*!40101 SET NAMES utf8 */"))
    }

    @Test("A comment that never ends leaves no keyword")
    func unterminatedComment() {
        #expect(mysqlLeadingKeyword("/* SHOW TABLES") == "")
        #expect(mysqlLeadingKeyword("-- SHOW TABLES") == "")
    }

    @Test("The keyword runs to the first character that is not a letter")
    func keywordBoundary() {
        #expect(mysqlLeadingKeyword("Show\tTables") == "SHOW")
        #expect(mysqlLeadingKeyword("SHOWX") == "SHOWX")
        #expect(mysqlLeadingKeyword("(SELECT 1)") == "")
    }
}
