//
//  MySQLPlanParserTests.swift
//  TableProTests
//
//  Tests for parsing MySQL EXPLAIN JSON and TREE output into a QueryPlan tree.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MySQL Plan Parser")
struct MySQLPlanParserTests {
    private let parser = MySQLPlanParser()

    private let analyzeOutput = [
        "-> Inner hash join (t2.c2 = t1.c1)  (cost=3.5 rows=5) (actual time=0.121..0.131 rows=1 loops=1)",
        "    -> Table scan on t2  (cost=0.07 rows=5) (actual time=0.0126..0.0221 rows=5 loops=1)",
        "    -> Hash",
        "        -> Table scan on t1  (cost=0.75 rows=5) (actual time=0.0372..0.0534 rows=5 loops=1)",
    ].joined(separator: "\n")

    @Test("Parses TREE hierarchy and ANALYZE metrics")
    func parsesTreeHierarchyAndMetrics() throws {
        let plan = try #require(parser.parse(rawText: analyzeOutput))

        #expect(plan.rootNode.operation == "Inner hash join (t2.c2 = t1.c1)")
        #expect(plan.rootNode.estimatedTotalCost == 3.5)
        #expect(plan.rootNode.estimatedRows == 5)
        #expect(plan.rootNode.actualStartupTime == 0.121)
        #expect(plan.rootNode.actualTotalTime == 0.131)
        #expect(plan.rootNode.actualRows == 1)
        #expect(plan.rootNode.actualLoops == 1)
        #expect(plan.executionTime == 0.131)
        #expect(plan.rootNode.children.count == 2)

        let tableScan = plan.rootNode.children[0]
        #expect(tableScan.operation == "Table scan")
        #expect(tableScan.relation == "t2")

        let hash = plan.rootNode.children[1]
        #expect(hash.operation == "Hash")
        #expect(hash.children.count == 1)
        #expect(hash.children[0].relation == "t1")
    }

    @Test("Extracts index details from access nodes")
    func extractsIndexDetails() throws {
        let output = """
        -> Index range scan on `orders archive` using `created_at_idx` over (created_at > 1)  \
        (cost=12.5 rows=42)
        """

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.operation == "Index range scan")
        #expect(plan.rootNode.relation == "`orders archive`")
        #expect(plan.rootNode.properties["Index Name"] == "`created_at_idx`")
        #expect(plan.rootNode.properties["Details"]?.contains("created_at > 1") == true)
    }

    @Test("Accepts engineering notation and averages across loops")
    func acceptsEngineeringNotation() throws {
        let output = """
        -> Table scan on huge_table  (cost=1.23e+9 rows=934e+6) \
        (actual time=934e-6..1.2e+6 rows=1.23e+3 loops=2)
        """

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.estimatedTotalCost == 1.23e+9)
        #expect(plan.rootNode.estimatedRows == 934_000_000)
        #expect(plan.rootNode.actualStartupTime == 934e-6)
        #expect(plan.rootNode.actualTotalTime == 1.2e+6)
        #expect(plan.rootNode.actualRows == 1_230)
        #expect(plan.rootNode.actualLoops == 2)
        #expect(plan.executionTime == 2.4e+6)
    }

    @Test("Joins wrapped metric lines")
    func joinsWrappedMetrics() throws {
        let output = [
            "-> Filter: (users.active = true)",
            "    (cost=4.2 rows=8)",
            "    (actual time=0.01..0.03 rows=7 loops=1)",
            "    -> Table scan on users  (cost=3 rows=10)",
        ].joined(separator: "\r\n")

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.estimatedTotalCost == 4.2)
        #expect(plan.rootNode.actualRows == 7)
        #expect(plan.rootNode.children.first?.relation == "users")
    }

    @Test("Keeps nodes that were never executed")
    func keepsNeverExecutedNodes() throws {
        let output = [
            "-> Nested loop inner join  (cost=5 rows=1)",
            "    -> Table scan on users  (cost=2 rows=1)",
            "    -> Index lookup on orders using user_id_idx  (cost=3 rows=1) (never executed)",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))
        let skipped = plan.rootNode.children[1]
        #expect(skipped.operation == "Index lookup")
        #expect(skipped.actualTotalTime == nil)
        #expect(skipped.properties["Execution"] == "Never executed")
    }

    @Test("Falls back to the existing JSON parser")
    func parsesJSONPlan() throws {
        let output = """
        {
          "query_block": {
            "cost_info": { "query_cost": "1.25" },
            "table": {
              "table_name": "users",
              "access_type": "ALL",
              "rows_examined_per_scan": 10
            }
          }
        }
        """

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.operation == "Query Block")
        #expect(plan.rootNode.estimatedTotalCost == 1.25)
        #expect(plan.rootNode.children.first?.relation == "users")
        #expect(plan.rootNode.children.first?.estimatedRows == 10)
    }

    @Test("Wraps multiple top-level iterators in one synthetic root")
    func wrapsMultipleRoots() throws {
        let output = [
            "-> Table scan on users  (cost=1 rows=1)",
            "-> Table scan on roles  (cost=3 rows=1)",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.operation == "Query Plan")
        #expect(plan.rootNode.children.count == 2)
        #expect(plan.rootNode.estimatedTotalCost == 4)
        #expect(plan.rootNode.costFraction == 0)
        #expect(plan.rootNode.children[0].costFraction == 0.25)
        #expect(plan.rootNode.children[1].costFraction == 0.75)
    }

    @Test("Reports the estimated cost even without a startup cost")
    func reportsCostWithoutStartupCost() throws {
        let plan = try #require(parser.parse(rawText: "-> Table scan on users  (cost=3.5 rows=5)"))

        #expect(plan.rootNode.estimatedStartupCost == nil)
        #expect(plan.rootNode.costRangeText(fractionDigits: 1) == "3.5")
        #expect(plan.rootNode.costRangeText(fractionDigits: 2) == "3.50")
    }

    @Test("Keeps node text that the query's own literals split across lines")
    func keepsSplitNodeText() throws {
        let output = [
            "-> Filter: (users.name = 'a",
            "b')  (cost=4.2 rows=8)",
            "    -> Table scan on users  (cost=3 rows=10)",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.operation == "Filter: (users.name = 'a b')")
        #expect(plan.rootNode.estimatedTotalCost == 4.2)
        #expect(plan.rootNode.estimatedRows == 8)
        #expect(plan.rootNode.children.first?.relation == "users")
    }

    @Test("Reads the index name when the relation is padded with extra spaces")
    func readsIndexNameAfterPaddedRelation() throws {
        let output = "-> Index lookup on  orders  using  customer_id_idx  (cost=2 rows=3)"

        let plan = try #require(parser.parse(rawText: output))
        #expect(plan.rootNode.operation == "Index lookup")
        #expect(plan.rootNode.relation == "orders")
        #expect(plan.rootNode.properties["Index Name"] == "customer_id_idx")
    }

    @Test("Rejects oversized JSON before it reaches JSONSerialization")
    func rejectsOversizedJSON() {
        let oversizedJson = "{\"query_block\": {\"comment\": \""
            + String(repeating: "x", count: 2_000_001)
            + "\"}}"
        #expect(parser.parse(rawText: oversizedJson) == nil)
    }

    @Test("Rejects malformed, oversized, and excessively deep input")
    func rejectsUnsafeInput() {
        #expect(parser.parse(rawText: "") == nil)
        #expect(parser.parse(rawText: "not a TREE plan") == nil)
        #expect(parser.parse(rawText: String(repeating: "x", count: 2_000_001)) == nil)

        let overflowingTime = "-> Scan  (actual time=1..1e308 rows=1 loops=1e18)"
        #expect(parser.parse(rawText: overflowingTime)?.executionTime == nil)

        let excessiveDepth = (0..<130)
            .map { String(repeating: " ", count: $0) + "-> Node \($0)" }
            .joined(separator: "\n")
        #expect(parser.parse(rawText: excessiveDepth) == nil)
    }

    @Test("MySQL and MariaDB resolve to the composite parser")
    func registryUsesCompositeParser() {
        for databaseType in [DatabaseType.mysql, .mariadb] {
            let format = ExplainFormatResolver.resolve(declared: .plainText, databaseType: databaseType)
            #expect(ExplainPlanParserRegistry.parser(for: format) is MySQLPlanParser)
        }
    }
}
