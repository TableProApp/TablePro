//
//  ExplainPlanFormatResolutionTests.swift
//  TableProTests
//
//  Tests for resolving an EXPLAIN plan format and mapping it to a parser.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Explain Plan Format Resolution")
struct ExplainPlanFormatResolutionTests {
    private let mysqlVariants = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .mysqlComposite),
        ExplainVariant(
            id: "json", label: "EXPLAIN (JSON)", sqlPrefix: "EXPLAIN FORMAT=JSON", format: .mysqlComposite
        ),
    ]

    private let sqliteVariants = [
        ExplainVariant(
            id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN", format: .sqliteQueryPlan
        )
    ]

    // MARK: - Registry

    @Test("Every known format maps to its parser")
    func mapsFormatsToParsers() {
        #expect(ExplainPlanParserRegistry.parser(for: .postgresJson) is PostgreSQLPlanParser)
        #expect(ExplainPlanParserRegistry.parser(for: .mysqlComposite) is MySQLPlanParser)
        #expect(ExplainPlanParserRegistry.parser(for: .sqliteQueryPlan) is SQLitePlanParser)
        #expect(ExplainPlanParserRegistry.parser(for: .cockroachText) is CockroachDBPlanParser)
        #expect(ExplainPlanParserRegistry.parser(for: .indentedText) is IndentedTextPlanParser)
        #expect(ExplainPlanParserRegistry.parser(for: .damengText) is DamengPlanParser)
    }

    @Test("Plain text and an unknown format have no parser")
    func degradesUnknownFormats() {
        #expect(ExplainPlanParserRegistry.parser(for: .plainText) == nil)
        #expect(ExplainPlanParserRegistry.parser(for: ExplainPlanFormat(rawValue: "future")) == nil)
    }

    // MARK: - Curated defaults

    @Test("A database type the app knows resolves a format even when the variant declares none")
    func fallsBackToCuratedDefault() {
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .pglite) == .postgresJson)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .redshift) == .postgresJson)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .cloudflareD1) == .sqliteQueryPlan)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .libsql) == .sqliteQueryPlan)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .turso) == .sqliteQueryPlan)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .cockroachdb) == .cockroachText)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .duckdb) == .indentedText)
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: .dameng) == .damengText)
    }

    @Test("A declared format always wins over the curated default")
    func declaredFormatWins() {
        #expect(ExplainFormatResolver.resolve(declared: .indentedText, databaseType: .postgresql) == .indentedText)
    }

    @Test("An unknown database type stays plain text")
    func unknownDatabaseTypeStaysPlainText() {
        let unknown = DatabaseType(rawValue: "SomeFutureEngine")
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: unknown) == .plainText)
    }

    // MARK: - Statement matching

    @Test("The longest matching prefix wins")
    func longestPrefixWins() {
        let matched = ExplainFormatResolver.matchingVariant(
            sql: "EXPLAIN FORMAT=JSON SELECT 1", declaredVariants: mysqlVariants
        )
        #expect(matched?.id == "json")
    }

    @Test("Prefix matching ignores case and leading whitespace")
    func matchesCaseInsensitively() {
        let matched = ExplainFormatResolver.matchingVariant(
            sql: "  explain query plan SELECT 1", declaredVariants: sqliteVariants
        )
        #expect(matched?.id == "plan")
    }

    @Test("A statement no variant declares has no match")
    func rejectsUndeclaredStatement() {
        #expect(ExplainFormatResolver.matchingVariant(sql: "ANALYZE TABLE users", declaredVariants: mysqlVariants) == nil)
        #expect(ExplainFormatResolver.matchingVariant(sql: "SELECT 1", declaredVariants: mysqlVariants) == nil)
        #expect(ExplainFormatResolver.matchingVariant(sql: "", declaredVariants: mysqlVariants) == nil)
    }

    @Test("A typed statement with no declared match still resolves the database default")
    func typedStatementFallsBackToDatabaseDefault() {
        let format = ExplainFormatResolver.resolve(
            sql: "EXPLAIN ANALYZE SELECT 1", databaseType: .mysql, declaredVariants: mysqlVariants
        )
        #expect(format == .mysqlComposite)
    }

    // MARK: - Flattening

    @Test("Single-column rows join with newlines")
    func flattensSingleColumn() {
        let rows: [[PluginCellValue]] = [[.text("a")], [.text("b")]]
        #expect(ExplainPlanTextFlattener.flatten(rows: rows) == "a\nb")
    }

    @Test("Multi-column rows join columns with tabs")
    func flattensMultipleColumns() {
        let rows: [[PluginCellValue]] = [
            [.text("1"), .text("0"), .text("0"), .text("SCAN users")],
            [.text("2"), .text("1"), .text("0"), .text("SEARCH orders")],
        ]
        #expect(ExplainPlanTextFlattener.flatten(rows: rows) == "1\t0\t0\tSCAN users\n2\t1\t0\tSEARCH orders")
    }

    @Test("No rows flatten to an empty string")
    func flattensEmptyRows() {
        #expect(ExplainPlanTextFlattener.flatten(rows: []).isEmpty)
    }
}
