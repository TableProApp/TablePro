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
        #expect(request.subjectSQL == "SELECT 1")
        #expect(request.format == .postgresJson)
        #expect(request.variantKey == .declared("explain"))
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
        #expect(request.subjectSQL == "SELECT 1")
        #expect(request.variantKey == .declared("analyze"))
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
        #expect(request.subjectSQL == "EXPLAIN SELECT 1")
        #expect(request.format == .indentedText)
        #expect(request.variantKey == .driverBuilt)
    }

    @Test("A driver-built statement retains a separately known subject")
    func driverBuiltRetainsSubject() {
        let request = ExplainRequest.driverBuilt(
            sql: "EXPLAIN SELECT 1",
            databaseType: .duckdb,
            subjectSQL: "SELECT 1"
        )

        #expect(request.subjectSQL == "SELECT 1")
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

    @Test("The result factory retains the run's plan-history provenance")
    @MainActor
    func resultFactoryRetainsPlanContext() {
        let built = QueryPlanCaptureBuilder.make(
            subjectSQL: "SELECT * FROM users",
            rawPlan: "[]",
            format: .postgresJson,
            variantKey: .declared("analyze"),
            scope: QueryPlanScope(
                connectionId: UUID(),
                databaseType: .postgresql,
                databaseName: "app",
                schemaName: "public"
            ),
            executionTime: 0.25,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyId: UUID(),
            queryParameters: nil
        )
        let result = ExplainResultSetFactory.make(
            rawText: "[]",
            plan: nil,
            sql: "EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM users",
            executionTime: 0.25,
            planContext: built.context
        )

        #expect(result.explainPlanContext == built.context)
        #expect(result.baseQuery == "EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM users")
    }

    /// A database is free to print bind values into its plan output, so a parameterized run keeps
    /// its history row and stores no plan. The pane says so rather than showing an empty list.
    @Test("A parameterized run stores no plan and explains why")
    func parameterizedRunStoresNoPlan() {
        let rawPlan = #"[{"Plan":{"Filter":"token = 'must-not-reach-history'"}}]"#
        let arguments = (
            subjectSQL: "SELECT * FROM users WHERE token = :secret",
            format: ExplainPlanFormat.postgresJson,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let unparameterized = QueryPlanCaptureBuilder.make(
            subjectSQL: arguments.subjectSQL,
            rawPlan: rawPlan,
            format: arguments.format,
            variantKey: .declared("explain"),
            scope: QueryPlanScope(
                connectionId: UUID(),
                databaseType: .postgresql,
                databaseName: "app",
                schemaName: "public"
            ),
            executionTime: 0.1,
            capturedAt: arguments.capturedAt,
            historyId: UUID(),
            queryParameters: nil
        )
        #expect(unparameterized.capture?.rawPlan == rawPlan)
        #expect(unparameterized.context.skipReason == nil)
        #expect(unparameterized.context.isStored)

        let parameterized = QueryPlanCaptureBuilder.make(
            subjectSQL: arguments.subjectSQL,
            rawPlan: rawPlan,
            format: arguments.format,
            variantKey: .declared("explain"),
            scope: QueryPlanScope(
                connectionId: UUID(),
                databaseType: .postgresql,
                databaseName: "app",
                schemaName: "public"
            ),
            executionTime: 0.1,
            capturedAt: arguments.capturedAt,
            historyId: UUID(),
            queryParameters: [QueryParameter(name: "secret", value: "must-not-reach-history")]
        )
        #expect(parameterized.capture == nil)
        #expect(parameterized.context.skipReason == .parameterized)
        #expect(!parameterized.context.isStored)
        #expect(!parameterized.context.skipReason!.explanation.isEmpty)
    }

    /// A plan bigger than the per-plan cap keeps the history row and reports why it was dropped.
    @Test("An oversized plan is skipped with a reason")
    func oversizedPlanIsSkipped() {
        let built = QueryPlanCaptureBuilder.make(
            subjectSQL: "SELECT 1",
            rawPlan: String(repeating: "x", count: QueryPlanStorageLimits.maximumPlanByteCount + 1),
            format: .postgresJson,
            variantKey: .declared("explain"),
            scope: QueryPlanScope(
                connectionId: UUID(),
                databaseType: .postgresql,
                databaseName: "app",
                schemaName: nil
            ),
            executionTime: 0.1,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyId: UUID(),
            queryParameters: nil
        )
        #expect(built.capture == nil)
        #expect(built.context.skipReason == .tooLarge)
    }

    /// Both EXPLAIN paths have to reach one chain. They build the identity through the same builder,
    /// so the same statement asked the same way hashes to the same identity whatever route it took.
    @Test("Reformatting a statement keeps it in the same chain")
    func reformattingKeepsOneChain() {
        func identity(_ sql: String) -> QueryPlanIdentity {
            QueryPlanCaptureBuilder.make(
                subjectSQL: sql,
                rawPlan: "[]",
                format: .postgresJson,
                variantKey: .declared("explain"),
                scope: QueryPlanScope(
                    connectionId: connectionId,
                    databaseType: .postgresql,
                    databaseName: "app",
                    schemaName: "public"
                ),
                executionTime: 0.1,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                historyId: UUID(),
                queryParameters: nil
            ).context.identity
        }

        #expect(identity("SELECT * FROM users WHERE id = 1")
            == identity("select *\n  from users\n where id = 2"))
        #expect(identity("SELECT * FROM users") != identity("SELECT * FROM orders"))
    }

    private let connectionId = UUID()

    private func repositoryRoot() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("TablePro.xcodeproj").path
            ) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return directory
    }
}
