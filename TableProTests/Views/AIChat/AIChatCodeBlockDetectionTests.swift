//
//  AIChatCodeBlockDetectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AIChatCodeBlockView.detectLanguage")
struct AIChatCodeBlockDetectionTests {
    @Test("SQL prefixes are detected case-insensitively")
    func sqlPrefixes() {
        #expect(AIChatCodeBlockView.detectLanguage(from: "SELECT * FROM users") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "select * from users") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "INSERT INTO t VALUES (1)") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "PRAGMA index_list('x')") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "EXPLAIN QUERY PLAN SELECT 1") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "WITH cte AS (SELECT 1) SELECT * FROM cte") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "SET @v = 1") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "CALL my_proc(1, 2)") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "SHOW TABLES") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "DESC users") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "DESCRIBE users") == "sql")
    }

    @Test("Leading SQL comments are skipped")
    func sqlAfterComments() {
        #expect(AIChatCodeBlockView.detectLanguage(from: "-- top comment\nSELECT 1") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "/* block */\nINSERT INTO t VALUES (1)") == "sql")
        #expect(AIChatCodeBlockView.detectLanguage(from: "  \n  -- spaces\n  SELECT 1") == "sql")
    }

    @Test("MongoDB-style db.* is detected as JavaScript")
    func mongoDetected() {
        #expect(AIChatCodeBlockView.detectLanguage(from: "db.users.find({})") == "javascript")
        #expect(AIChatCodeBlockView.detectLanguage(from: "DB.collection.aggregate([])") == "javascript")
    }

    @Test("Non-code or unrecognized content returns nil")
    func unknownReturnsNil() {
        #expect(AIChatCodeBlockView.detectLanguage(from: "Hello world") == nil)
        #expect(AIChatCodeBlockView.detectLanguage(from: "") == nil)
        #expect(AIChatCodeBlockView.detectLanguage(from: "   ") == nil)
        #expect(AIChatCodeBlockView.detectLanguage(from: "console.log('hi')") == nil)
        #expect(AIChatCodeBlockView.detectLanguage(from: "import Foundation") == nil)
    }
}
