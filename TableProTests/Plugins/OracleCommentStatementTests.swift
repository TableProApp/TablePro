//
//  OracleCommentStatementTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct OracleCommentStatementTests {
    private static let name = "\"HR\".\"T\""

    private func statement(_ objectType: String, _ comment: String?) -> String? {
        OracleObjectQueries.commentStatement(qualifiedName: Self.name, objectType: objectType, comment: comment)
    }

    @Test("A table, a partitioned table and a view take the TABLE keyword", arguments: ["TABLE", "PARTITIONED TABLE", "VIEW"])
    func tableKeyword(kind: String) {
        #expect(statement(kind, "c") == "COMMENT ON TABLE \"HR\".\"T\" IS 'c'")
    }

    @Test("A materialized view takes its own keyword")
    func materializedViewKeyword() {
        #expect(statement("MATERIALIZED VIEW", "c") == "COMMENT ON MATERIALIZED VIEW \"HR\".\"T\" IS 'c'")
    }

    @Test("Other kinds cannot be commented", arguments: ["SEQUENCE", "SYSTEM TABLE", "FOREIGN TABLE", ""])
    func otherKinds(kind: String) {
        #expect(statement(kind, nil) == nil)
    }

    /// Oracle removes a comment only when it is set to the empty string.
    @Test("A nil or empty comment is written as the empty string")
    func emptyCommentClears() {
        #expect(statement("TABLE", nil) == "COMMENT ON TABLE \"HR\".\"T\" IS ''")
        #expect(statement("TABLE", "") == "COMMENT ON TABLE \"HR\".\"T\" IS ''")
    }

    @Test("A comment doubles its quotes and drops NUL")
    func commentEscaping() {
        #expect(statement("TABLE", "it's\0 here") == "COMMENT ON TABLE \"HR\".\"T\" IS 'it''s here'")
    }

    @Test("A quote followed by a combining mark is still doubled")
    func quoteBeforeCombiningMark() {
        #expect(statement("TABLE", "a'\u{301}b") == "COMMENT ON TABLE \"HR\".\"T\" IS 'a''\u{301}b'")
        #expect(OracleObjectQueries.quoteIdentifier("x\"\u{301}") == "\"x\"\"\u{301}\"")
    }

    @Test("A column comment names the column inside the table")
    func columnComment() {
        #expect(OracleObjectQueries.columnCommentStatement(qualifiedTable: Self.name, column: "c\"x", comment: "d")
            == "COMMENT ON COLUMN \"HR\".\"T\".\"c\"\"x\" IS 'd'")
    }
}
