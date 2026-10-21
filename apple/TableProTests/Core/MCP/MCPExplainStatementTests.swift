//
//  MCPExplainStatementTests.swift
//  TableProTests
//
//  explain_query made up an `EXPLAIN` prefix for any engine that declares no explain variant, so
//  Redis was sent `EXPLAIN GET k`, and answered `analyze` with the first variant, which returned
//  an estimate to a caller that asked for a measured run.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@MainActor
struct MCPExplainStatementTests {
    private func message(of attempt: () throws -> String) -> String? {
        do {
            _ = try attempt()
            return nil
        } catch let error as DatabaseAccessError {
            guard case .invalidArgument(let detail) = error else { return nil }
            return detail
        } catch {
            return nil
        }
    }

    private func statement(_ query: String, _ type: DatabaseType, variant: String? = nil, analyze: Bool = false) throws -> String {
        try MCPConnectionBridge.explainStatement(for: query, databaseType: type, variantId: variant, analyze: analyze)
    }

    @Test("An engine that declares no explain variant gets no invented EXPLAIN")
    func engineWithoutVariantsIsRefused() throws {
        let refusal = String(localized: "This database does not explain statements.")
        #expect(message { try statement("GET k", .redis) } == refusal)
        #expect(message { try statement("GET k", .redis, analyze: true) } == refusal)
        #expect(try statement("EXPLAIN GET k", .redis) == "EXPLAIN GET k")
    }

    @Test("A declared variant prefixes the statement, and analyze picks the one that runs it")
    func declaredVariantPrefixes() throws {
        #expect(try statement("SELECT 1", .cockroachdb) == "EXPLAIN SELECT 1")
        #expect(try statement("SELECT 1", .cockroachdb, analyze: true) == "EXPLAIN ANALYZE SELECT 1")
    }

    @Test("Analyze on an engine with no variant that runs the statement is refused, naming the variants")
    func analyzeWithoutRunningVariantIsRefused() throws {
        let refusal = message { try statement("SELECT 1", .redshift, analyze: true) }
        #expect(refusal?.contains("explain, verbose") == true)
        #expect(message { try statement("SELECT 1", .redshift, variant: "verbose", analyze: true) } == refusal)
        #expect(try statement("SELECT 1", .redshift, variant: "verbose") == "EXPLAIN VERBOSE SELECT 1")
    }

    @Test("A variant that only estimates cannot answer analyze, and the refusal names the ones that run")
    func estimatingVariantRefusesAnalyze() throws {
        let refusal = message { try statement("SELECT 1", .cockroachdb, variant: "explain", analyze: true) }
        #expect(refusal == String(
            format: String(
                localized: "The '%1$@' variant does not run the statement. Leave 'analyze' off, or pass one that does: %2$@."
            ),
            "explain",
            "analyze"
        ))
        #expect(try statement("SELECT 1", .cockroachdb, variant: "analyze", analyze: true) == "EXPLAIN ANALYZE SELECT 1")
        #expect(try statement("SELECT 1", .cockroachdb, variant: "analyze") == "EXPLAIN ANALYZE SELECT 1")
    }

    @Test("An unknown variant names the ones the engine offers")
    func unknownVariantNamesOffered() {
        #expect(message { try statement("SELECT 1", .redshift, variant: "nope") }?.contains("explain, verbose") == true)
    }

    @Test("A typed EXPLAIN on an engine that explains is passed through")
    func typedExplainPassesThrough() throws {
        #expect(try statement("EXPLAIN SELECT 1", .postgresql) == "EXPLAIN SELECT 1")
    }

    @Test("Teradata's EXPLAIN request modifier is offered")
    func teradataExplains() throws {
        #expect(try statement("SELECT 1", .teradata) == "EXPLAIN SELECT 1")
    }

    private static let driverVariants = [
        ExplainVariant.driverPlan(id: "estimated", label: "Estimated Plan", format: .oraclePlanRows, runsStatement: false),
        ExplainVariant.driverPlan(id: "actual", label: "Actual Plan", format: .oraclePlanRows, runsStatement: true),
    ]

    private func driverRequest(_ query: String, variant: String? = nil, analyze: Bool = false) throws -> MCPExplainRequest {
        try MCPConnectionBridge.explainRequest(
            for: query, databaseType: .oracle, variants: Self.driverVariants, variantId: variant, analyze: analyze
        )
    }

    @Test("A driver plan sends the statement alone, and one that only plans it is gated as a plain EXPLAIN")
    func driverPlanIsGatedAsExplain() throws {
        let request = try driverRequest("DELETE FROM t")
        #expect(request.statement == "DELETE FROM t")
        #expect(request.gatedSQL == "EXPLAIN DELETE FROM t")
        #expect(request.driverStep == ExplainRequest.DriverStep(variantId: "estimated", runsStatement: false))
        #expect(QueryClassifier.classifyTier(request.gatedSQL, databaseType: .oracle) == .safe)
    }

    @Test("An estimated driver plan of a SET is gated as the SET, which SQL Server runs even with SHOWPLAN on")
    func unplannedStatementIsGatedAsItself() throws {
        let request = try driverRequest("SET IMPLICIT_TRANSACTIONS ON")
        #expect(request.gatedSQL == "SET IMPLICIT_TRANSACTIONS ON")
        #expect(QueryClassifier.classifyTier(request.gatedSQL, databaseType: .mssql) != .safe)
    }

    @Test("Analyze picks the driver plan that runs the statement, and gates the statement itself")
    func analyzePicksRunningDriverPlan() throws {
        let request = try driverRequest("DELETE FROM t", analyze: true)
        #expect(request.gatedSQL == "DELETE FROM t")
        #expect(request.driverStep == ExplainRequest.DriverStep(variantId: "actual", runsStatement: true))
        #expect(QueryClassifier.classifyTier(request.gatedSQL, databaseType: .oracle) != .safe)
    }

    @Test("An estimated driver plan cannot answer analyze")
    func estimatedDriverPlanRefusesAnalyze() {
        let refusal = message { try driverRequest("SELECT 1", variant: "estimated", analyze: true).statement }
        #expect(refusal == String(
            format: String(
                localized: "The '%1$@' variant does not run the statement. Leave 'analyze' off, or pass one that does: %2$@."
            ),
            "estimated",
            "actual"
        ))
    }

    @Test("The variant listing says which variants run the statement")
    func variantListingSaysWhichRun() {
        let listed = MCPConnectionBridge.explainVariants(for: .cockroachdb)
        guard case .array(let entries) = listed else {
            Issue.record("Expected an array")
            return
        }
        let running = entries.compactMap { entry -> String? in
            guard case .object(let fields) = entry, fields["runs_statement"] == .bool(true),
                  case .string(let id)? = fields["id"] else { return nil }
            return id
        }
        #expect(running == ["analyze"])
    }
}

@Suite("Plugin metadata registry - explain variants", .serialized)
struct PluginMetadataRegistryExplainVariantTests {
    private let registry = PluginMetadataRegistry.shared

    /// DuckDB's plugin declares no variants, and registering it used to replace the curated
    /// `EXPLAIN` with nothing, which took Explain away the moment the plugin loaded.
    @Test("A plugin that declares no explain variants keeps the curated ones")
    func emptyPluginListKeepsCurated() throws {
        let curated = try #require(registry.snapshot(for: .duckdb))
        defer { registry.unregister(typeId: "DuckDB") }
        registry.register(snapshot: curated.withExplainVariants([]), forTypeId: "DuckDB")

        #expect(registry.snapshot(for: .duckdb)?.explainVariants.map(\.id) == curated.explainVariants.map(\.id))
        #expect(registry.snapshot(for: .duckdb)?.explainVariants.isEmpty == false)
    }

    @Test("A plugin's own explain variants win over the curated ones")
    func pluginListWins() throws {
        let curated = try #require(registry.snapshot(for: .duckdb))
        defer { registry.unregister(typeId: "DuckDB") }
        let own = ExplainVariant(id: "own", label: "Own", sqlPrefix: "EXPLAIN ANALYZE", format: .plainText)
        registry.register(snapshot: curated.withExplainVariants([own]), forTypeId: "DuckDB")

        #expect(registry.snapshot(for: .duckdb)?.explainVariants.map(\.id) == ["own"])
    }

    @Test("Oracle and SQL Server enable Explain only through a plugin that runs its own plans")
    func driverPlanEnginesHaveNoCuratedVariants() throws {
        for type in [DatabaseType.oracle, .mssql] {
            let curated = try #require(registry.snapshot(for: type))
            #expect(curated.explainVariants.isEmpty)
            defer { registry.unregister(typeId: type.rawValue) }
            let estimated = ExplainVariant.driverPlan(
                id: "estimated", label: "Estimated Plan", format: .sqlServerShowplanXML, runsStatement: false
            )
            registry.register(snapshot: curated.withExplainVariants([estimated]), forTypeId: type.rawValue)
            #expect(registry.snapshot(for: type)?.explainVariants.map(\.id) == ["estimated"])
        }
    }

    @Test("An engine with no curated explain variants stays without Explain")
    func noCuratedVariantsStaysOff() throws {
        let curated = try #require(registry.snapshot(for: .redis))
        defer { registry.unregister(typeId: "Redis") }
        registry.register(snapshot: curated.withExplainVariants([]), forTypeId: "Redis")

        #expect(registry.snapshot(for: .redis)?.explainVariants.isEmpty == true)
    }

    /// Redshift takes `EXPLAIN [VERBOSE]` only; PostgreSQL's `FORMAT JSON` and `ANALYZE` are syntax
    /// errors there, and the curated list is what `registerVariant` keeps.
    @Test("Redshift keeps its own variants over PostgreSQL's")
    func redshiftKeepsItsOwn() throws {
        let postgres = try #require(registry.snapshot(for: .postgresql))
        defer { registry.unregister(typeId: "Redshift") }
        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "Redshift", primaryTypeId: "PostgreSQL")

        #expect(registry.snapshot(for: .redshift)?.explainVariants.map(\.sqlPrefix) == ["EXPLAIN", "EXPLAIN VERBOSE"])
        #expect(ExplainPlanFormatDefaults.format(for: .redshift) == .plainText)
        #expect(ExplainPlanFormatDefaults.format(for: .pglite) == .postgresJson)
    }
}
