//
//  ExplainRequestTests.swift
//  TableProTests
//
//  Tests for choosing which EXPLAIN variant runs and what format its output is read as.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Explain Request")
struct ExplainRequestTests {
    private let postgresVariants = [
        ExplainVariant(
            id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .postgresJson
        ),
        ExplainVariant(
            id: "analyze",
            label: "EXPLAIN ANALYZE",
            sqlPrefix: "EXPLAIN (ANALYZE, FORMAT JSON)",
            format: .postgresJson
        ),
    ]

    @Test("With no explicit choice the first declared variant runs")
    func defaultsToFirstDeclaredVariant() throws {
        let request = try #require(
            ExplainRequest.make(
                variant: nil,
                declaredVariants: postgresVariants,
                databaseType: .postgresql,
                statement: "SELECT 1"
            )
        )

        #expect(request.sql == "EXPLAIN (FORMAT JSON) SELECT 1")
        #expect(request.format == .postgresJson)
    }

    @Test("An explicit variant overrides the default")
    func explicitVariantWins() throws {
        let request = try #require(
            ExplainRequest.make(
                variant: postgresVariants[1],
                declaredVariants: postgresVariants,
                databaseType: .postgresql,
                statement: "SELECT 1"
            )
        )

        #expect(request.sql == "EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1")
    }

    @Test("A driver that declares no variants has no request to build")
    func returnsNilWithoutVariants() {
        #expect(
            ExplainRequest.make(
                variant: nil, declaredVariants: [], databaseType: .mongodb, statement: "SELECT 1"
            ) == nil
        )
    }

    @Test("A variant that names no format falls back to the database default")
    func untaggedVariantUsesDatabaseDefault() throws {
        let untagged = ExplainVariant(id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN")
        let request = try #require(
            ExplainRequest.make(
                variant: untagged,
                declaredVariants: [untagged],
                databaseType: .cloudflareD1,
                statement: "SELECT 1"
            )
        )

        #expect(request.format == .sqliteQueryPlan)
    }

    @Test("A driver-built statement still resolves the database default format")
    func driverBuiltUsesDatabaseDefault() {
        let request = ExplainRequest.driverBuilt(sql: "EXPLAIN SELECT 1", databaseType: .duckdb)

        #expect(request.sql == "EXPLAIN SELECT 1")
        #expect(request.format == .indentedText)
    }

    @Test("A driver-built statement is marked so it keeps the ordinary result grid")
    func driverBuiltIsFlagged() {
        #expect(ExplainRequest.driverBuilt(sql: "DEBUG OBJECT key", databaseType: .redis).isDriverBuilt)
    }

    @Test("A declared variant is not driver-built")
    func declaredVariantIsNotDriverBuilt() throws {
        let request = try #require(
            ExplainRequest.make(
                variant: nil,
                declaredVariants: postgresVariants,
                databaseType: .postgresql,
                statement: "SELECT 1"
            )
        )
        #expect(!request.isDriverBuilt)
    }

    @Test("A driver-built statement on an unknown engine stays plain text")
    func driverBuiltOnUnknownEngineStaysPlainText() {
        let request = ExplainRequest.driverBuilt(sql: "DEBUG OBJECT key", databaseType: .redis)
        #expect(request.format == .plainText)
    }
}
