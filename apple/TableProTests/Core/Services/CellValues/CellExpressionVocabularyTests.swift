//
//  CellExpressionVocabularyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct CellExpressionVocabularyTests {
    private static func sql(_ databaseType: DatabaseType, _ columnType: ColumnType) -> [String] {
        CellExpressionVocabulary.expressions(for: databaseType, columnType: columnType).map(\.sql)
    }

    @Test("A column's kind comes from its type, time-only and timeuuid included")
    func kinds() {
        #expect(CellExpressionKind(columnType: .timestamp(rawType: "TIMESTAMP")) == .timestamp)
        #expect(CellExpressionKind(columnType: .datetime(rawType: "DATETIME")) == .datetime)
        #expect(CellExpressionKind(columnType: .date(rawType: "DATE")) == .date)
        #expect(CellExpressionKind(columnType: .timestamp(rawType: "TIME")) == .time)
        #expect(CellExpressionKind(columnType: .datetime(rawType: "time(7)")) == .time)
        #expect(CellExpressionKind(columnType: .text(rawType: "timeuuid")) == .timeUUID)
        #expect(CellExpressionKind(columnType: .text(rawType: "uuid")) == nil)
        #expect(CellExpressionKind(columnType: .text(rawType: "VARCHAR(20)")) == nil)
    }

    @Test("PostgreSQL offers only spellings it parses, per column kind")
    func postgreSQL() {
        #expect(Self.sql(.postgresql, .timestamp(rawType: "timestamptz")) == ["now()", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP"])
        #expect(Self.sql(.postgresql, .date(rawType: "date")) == ["CURRENT_DATE"])
        #expect(Self.sql(.postgresql, .timestamp(rawType: "time")) == ["CURRENT_TIME", "LOCALTIME"])
        #expect(Self.sql(.pglite, .date(rawType: "date")) == ["CURRENT_DATE"])
    }

    @Test("A text or UUID column takes no expression")
    func nonTemporalColumns() {
        #expect(Self.sql(.postgresql, .text(rawType: "varchar")).isEmpty)
        #expect(Self.sql(.postgresql, .text(rawType: "uuid")).isEmpty)
        #expect(CellExpressionVocabulary.expressions(for: .postgresql, columnType: nil).isEmpty)
    }

    @Test("An engine with no vocabulary gets nothing", arguments: [
        DatabaseType.mongodb, .redis, DatabaseType(rawValue: "SomeFuturePlugin")
    ])
    func unknownEngines(databaseType: DatabaseType) {
        #expect(CellExpressionVocabulary.expressions(for: databaseType).isEmpty)
        #expect(!CellExpressionVocabulary.isCanonical("NOW()", for: databaseType))
    }

    @Test("Typed text matches case-insensitively and trimmed, and resolves to the canonical spelling")
    func typedMatch() {
        let match = CellExpressionVocabulary.expression(
            typed: "  NOW()  ", databaseType: .postgresql, columnType: .timestamp(rawType: "timestamp")
        )
        #expect(match?.sql == "now()")
    }

    @Test("A spelling that saved before keeps working on MySQL through its alias", arguments: [
        ("CURRENT_DATE", ColumnType.date(rawType: "DATE"), "CURDATE()"),
        ("current_date()", .date(rawType: "DATE"), "CURDATE()"),
        ("CURRENT_TIME", .timestamp(rawType: "TIME"), "CURTIME()"),
        ("LOCALTIMESTAMP", .datetime(rawType: "DATETIME"), "NOW()"),
        ("sysdate()", .timestamp(rawType: "TIMESTAMP"), "SYSDATE()"),
        ("CURRENT_TIMESTAMP()", .datetime(rawType: "DATETIME"), "CURRENT_TIMESTAMP"),
    ])
    func mySQLAliases(typed: String, columnType: ColumnType, canonical: String) {
        let match = CellExpressionVocabulary.expression(typed: typed, databaseType: .mysql, columnType: columnType)
        #expect(match?.sql == canonical)
    }

    @Test("A spelling the engine rejects is not an expression there")
    func rejectedSpellings() {
        #expect(CellExpressionVocabulary.expression(
            typed: "CURRENT_TIMESTAMP()", databaseType: .postgresql, columnType: .timestamp(rawType: "timestamp")
        ) == nil)
        #expect(CellExpressionVocabulary.expression(
            typed: "NOW()", databaseType: .sqlite, columnType: .datetime(rawType: "DATETIME")
        ) == nil)
        #expect(CellExpressionVocabulary.expression(
            typed: "UNIX_TIMESTAMP()", databaseType: .mysql, columnType: .timestamp(rawType: "TIMESTAMP")
        ) == nil)
    }

    @Test("Typed text must fit the column's kind")
    func kindGate() {
        #expect(CellExpressionVocabulary.expression(
            typed: "CURRENT_TIME", databaseType: .sqlite, columnType: .datetime(rawType: "DATETIME")
        ) == nil)
        #expect(CellExpressionVocabulary.expression(
            typed: "now()", databaseType: .postgresql, columnType: .text(rawType: "varchar")
        ) == nil)
    }

    @Test("ClickHouse is spelled in lowercase, the only case today() resolves in")
    func clickHouse() {
        #expect(Self.sql(.clickhouse, .datetime(rawType: "DateTime")) == ["now()"])
        #expect(Self.sql(.clickhouse, .date(rawType: "Date")) == ["today()"])
        #expect(CellExpressionVocabulary.expression(
            typed: "CURDATE()", databaseType: .clickhouse, columnType: .date(rawType: "Date")
        )?.sql == "today()")
    }

    @Test("SQL Server fills a date or time column from the current moment too")
    func sqlServer() {
        #expect(Self.sql(.mssql, .date(rawType: "date")) == ["SYSDATETIME()", "GETDATE()"])
        #expect(Self.sql(.mssql, .timestamp(rawType: "time")) == ["SYSDATETIME()", "GETDATE()"])
        #expect(Self.sql(.mssql, .datetime(rawType: "datetime2")).count == 5)
    }

    @Test("Cassandra fills a timeuuid with now()")
    func cassandraTimeUUID() {
        #expect(Self.sql(.cassandra, .text(rawType: "timeuuid")) == ["now()", "currentTimeUUID()"])
        #expect(Self.sql(.scylladb, .timestamp(rawType: "timestamp")) == ["currentTimestamp()"])
        #expect(CellExpressionVocabulary.expression(
            typed: "toTimestamp(now())", databaseType: .cassandra, columnType: .timestamp(rawType: "timestamp")
        )?.sql == "currentTimestamp()")
    }

    @Test("BigQuery has its own function for each of timestamp and datetime")
    func bigQuery() {
        #expect(Self.sql(.bigQuery, .timestamp(rawType: "TIMESTAMP")) == ["CURRENT_TIMESTAMP()"])
        #expect(Self.sql(.bigQuery, .datetime(rawType: "DATETIME")) == ["CURRENT_DATETIME()"])
    }

    @Test("Canonical means exactly the vocabulary's spelling")
    func canonical() {
        #expect(CellExpressionVocabulary.isCanonical("now()", for: .postgresql))
        #expect(!CellExpressionVocabulary.isCanonical("NOW()", for: .postgresql))
        #expect(!CellExpressionVocabulary.isCanonical("now(); DROP TABLE t", for: .postgresql))
        #expect(CellExpressionVocabulary.isCanonical("CURDATE()", for: .mariadb))
        #expect(!CellExpressionVocabulary.isCanonical("CURRENT_DATE", for: .mariadb))
    }

    @Test("UPDATE takes DEFAULT except where its grammar has none", arguments: [
        (DatabaseType.sqlite, false), (.libsql, false), (.turso, false), (.cloudflareD1, false),
        (.clickhouse, false), (.databend, false), (.snowflake, false), (.trino, false), (.presto, false),
        (.cassandra, false), (.scylladb, false),
        (.postgresql, true), (.mysql, true), (.mssql, true), (.oracle, true), (.duckdb, true),
    ])
    func updateTakesDefault(databaseType: DatabaseType, expected: Bool) {
        #expect(CellExpressionVocabulary.updateTakesDefault(databaseType) == expected)
    }
    @Test("KingbaseES offers the expressions of its PostgreSQL dialect")
    func kingbaseExpressions() {
        #expect(Self.sql(.kingbasees, .timestamp(rawType: "TIMESTAMP"))
            == Self.sql(.postgresql, .timestamp(rawType: "TIMESTAMP")))
        #expect(CellExpressionVocabulary.isCanonical("now()", for: .kingbasees))
    }
}
