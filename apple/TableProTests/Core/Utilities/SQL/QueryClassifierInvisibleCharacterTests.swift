//
//  QueryClassifierInvisibleCharacterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct QueryClassifierInvisibleCharacterTests {
    @Test(
        "A read behind a leading invisible character is still a read",
        arguments: [
            "\u{0008}SELECT 1",
            "\u{FEFF}SELECT 1",
            "\u{200B}SELECT 1",
            "\u{00A0}SELECT 1",
            "\u{3000}SELECT 1",
            "\u{200E}\u{2060}SELECT 1",
            "\u{E0020}SELECT 1",
            "\u{FE0F}SELECT 1",
            "-- note\n\u{FEFF}SELECT 1",
            "/* note */\u{0008}SELECT 1",
            "(\u{200B}SELECT 1)",
        ]
    )
    func leadingInvisibleRead(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .safe)
    }

    @Test(
        "A destructive statement behind a leading invisible character is still destructive",
        arguments: ["\u{FEFF}DROP TABLE users", "\u{0008}TRUNCATE users", "\u{200B}DELETE FROM users"]
    )
    func leadingInvisibleDestructive(sql: String) {
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .postgresql))
    }

    @Test("A write behind a leading invisible character is still a write")
    func leadingInvisibleWrite() {
        #expect(QueryClassifier.classifyTier("\u{FEFF}UPDATE t SET a = 1", databaseType: .mysql) == .write)
        #expect(QueryClassifier.classifyTier("\u{0008}INSERT INTO t VALUES (1)", databaseType: .mysql) == .write)
    }

    @Test(
        "An invisible character inside the keyword hides it, so the statement stays a write",
        arguments: ["SEL\u{200B}ECT 1", "SEL\u{FEFF}ECT 1", "\u{FEFF}SEL\u{0008}ECT 1", "(SEL\u{00A0}ECT 1)"]
    )
    func invisibleInsideTheKeyword(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .write)
    }

    @Test(
        "A blank SQL Server reads as a space between two words is the space it is read as",
        arguments: ["\u{01}", "\u{08}", "\u{1F}", "\u{7F}", "\u{200B}", "\u{200C}", "\u{FEFF}"]
    )
    func blankBetweenWords(blank: String) {
        for sql in ["SELECT NEXT\(blank)VALUE FOR dbo.orders_seq", "SELECT NEXT VALUE\(blank)FOR dbo.orders_seq"] {
            #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .write, "\(sql)")
        }
        let auditFile = "SELECT * FROM sys.fn_get_audit_file\(blank)('C:\\a.sqlaudit', DEFAULT, DEFAULT)"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(auditFile, databaseType: .mssql))
        #expect(QueryClassifier.isDangerousQuery("ALTER TABLE t\(blank)DROP\(blank)COLUMN c", databaseType: .mssql))
        #expect(QueryClassifier.classifyTier("SELECT 'NEXT\(blank)VALUE FOR s'", databaseType: .mssql) == .safe)
    }

    @Test(
        "A filler that is a letter belongs to the word after it",
        arguments: ["\u{3164}SELECT 1", "\u{115F}SELECT 1", "\u{FFA0}SELECT 1"]
    )
    func letterFillerIsNotSkipped(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .write)
    }

    @Test("A visible mark on a leading blank is content, so the statement stays a write")
    func markedBlankIsNotSkipped() {
        #expect(QueryClassifier.classifyTier("\u{00A0}\u{0301}SELECT 1", databaseType: .postgresql) == .write)
    }

    @Test("A Redis command behind a leading invisible character keeps its tier")
    func redisCommandBehindInvisibleCharacter() {
        #expect(QueryClassifier.classifyTier("\u{FEFF}FLUSHALL", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("\u{0008}GET key", databaseType: .redis) == .safe)
    }

    @Test("A leading invisible character does not hide an EXPLAIN")
    func explainBehindInvisibleCharacter() {
        #expect(QueryClassifier.isExplainStatement("\u{FEFF}EXPLAIN SELECT 1", grammar: .ansi))
        #expect(QueryClassifier.explainedStatement(in: "\u{0008}EXPLAIN SELECT 1", databaseType: .postgresql) == "SELECT 1")
    }
}
