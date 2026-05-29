//
//  QueryClassifierTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("QueryClassifier isExplainStatement")
struct QueryClassifierExplainTests {
    @Test("Detects EXPLAIN and EXPLAIN ANALYZE variants")
    func detectsExplainVariants() {
        #expect(QueryClassifier.isExplainStatement("EXPLAIN SELECT * FROM users"))
        #expect(QueryClassifier.isExplainStatement("explain analyze select o.user_id from orders o"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN ANALYZE SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN FORMAT=JSON SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN (ANALYZE, BUFFERS) SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN(FORMAT JSON) SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN QUERY PLAN SELECT 1"))
    }

    @Test("Detects MariaDB ANALYZE statements")
    func detectsAnalyzeVariants() {
        #expect(QueryClassifier.isExplainStatement("ANALYZE FORMAT=JSON SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("analyze select 1"))
    }

    @Test("Ignores leading whitespace, newlines, and comments")
    func handlesWhitespaceAndComments() {
        #expect(QueryClassifier.isExplainStatement("   EXPLAIN SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("\n\tEXPLAIN\nSELECT 1"))
        #expect(QueryClassifier.isExplainStatement("-- plan check\nEXPLAIN SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("/* warm cache */ EXPLAIN ANALYZE SELECT 1"))
    }

    @Test("Does not match DESCRIBE, identifiers, or other statements")
    func rejectsNonExplain() {
        #expect(!QueryClassifier.isExplainStatement("DESCRIBE users"))
        #expect(!QueryClassifier.isExplainStatement("DESC users"))
        #expect(!QueryClassifier.isExplainStatement("SELECT * FROM explain_logs"))
        #expect(!QueryClassifier.isExplainStatement("SELECT explain FROM t"))
        #expect(!QueryClassifier.isExplainStatement("EXPLAINING SELECT 1"))
        #expect(!QueryClassifier.isExplainStatement("EXPLAIN"))
        #expect(!QueryClassifier.isExplainStatement(""))
    }
}
