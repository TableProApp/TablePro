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

@Suite("QueryClassifier classification with leading comments")
struct QueryClassifierLeadingCommentTests {
    @Test("isWriteQuery detects writes preceded by comments")
    func writeDetectionWithComments() {
        #expect(QueryClassifier.isWriteQuery("-- cleanup\nDELETE FROM users", databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery("/* batch */ INSERT INTO t VALUES (1)", databaseType: .postgresql))
        #expect(!QueryClassifier.isWriteQuery("-- note\nSELECT * FROM users", databaseType: .mysql))
    }

    @Test("isDangerousQuery detects destructive statements preceded by comments")
    func dangerousDetectionWithComments() {
        #expect(QueryClassifier.isDangerousQuery("-- reset\nDROP TABLE users", databaseType: .mysql))
        #expect(QueryClassifier.isDangerousQuery("/* wipe */ TRUNCATE users", databaseType: .postgresql))
        #expect(QueryClassifier.isDangerousQuery("-- purge\nDELETE FROM users", databaseType: .mysql))
        #expect(!QueryClassifier.isDangerousQuery("-- purge\nDELETE FROM users WHERE id = 1", databaseType: .mysql))
    }

    @Test("classifyTier classifies statements preceded by comments")
    func tierClassificationWithComments() {
        #expect(QueryClassifier.classifyTier("-- reset\nDROP TABLE users", databaseType: .mysql) == .destructive)
        #expect(QueryClassifier.classifyTier("/* batch */ UPDATE t SET x = 1", databaseType: .mysql) == .write)
        #expect(QueryClassifier.classifyTier("-- note\nSELECT 1", databaseType: .mysql) == .safe)
    }
}
