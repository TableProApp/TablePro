//
//  PostgreSQLPlanParserTests.swift
//  TableProTests
//
//  Tests for parsing PostgreSQL EXPLAIN (FORMAT JSON) output into a QueryPlan tree.
//

import Foundation
@testable import TablePro
import Testing

@Suite("PostgreSQL Plan Parser")
struct PostgreSQLPlanParserTests {
    private let parser = PostgreSQLPlanParser()

    private let estimatedPlan = """
    [
      {
        "Plan": {
          "Node Type": "Hash Join",
          "Join Type": "Inner",
          "Startup Cost": 1.09,
          "Total Cost": 40.35,
          "Plan Rows": 220,
          "Plan Width": 68,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Relation Name": "orders",
              "Schema": "public",
              "Alias": "o",
              "Startup Cost": 0.00,
              "Total Cost": 30.20,
              "Plan Rows": 200,
              "Plan Width": 36,
              "Filter": "(status = 'paid'::text)"
            },
            {
              "Node Type": "Hash",
              "Startup Cost": 1.04,
              "Total Cost": 1.04,
              "Plan Rows": 4,
              "Plan Width": 32
            }
          ]
        }
      }
    ]
    """

    @Test("Parses the node tree, costs and relations")
    func parsesEstimatedPlan() throws {
        let plan = try #require(parser.parse(rawText: estimatedPlan))

        #expect(plan.rootNode.operation == "Hash Join")
        #expect(plan.rootNode.estimatedStartupCost == 1.09)
        #expect(plan.rootNode.estimatedTotalCost == 40.35)
        #expect(plan.rootNode.estimatedRows == 220)
        #expect(plan.rootNode.estimatedWidth == 68)
        #expect(plan.rootNode.children.count == 2)

        let seqScan = plan.rootNode.children[0]
        #expect(seqScan.operation == "Seq Scan")
        #expect(seqScan.relation == "orders")
        #expect(seqScan.schema == "public")
        #expect(seqScan.alias == "o")
        #expect(seqScan.costRangeText(fractionDigits: 2) == "0.00..30.20")
    }

    @Test("Keeps unrecognised keys as node properties")
    func keepsExtraKeysAsProperties() throws {
        let plan = try #require(parser.parse(rawText: estimatedPlan))

        #expect(plan.rootNode.properties["Join Type"] == "Inner")
        #expect(plan.rootNode.children[0].properties["Filter"] == "(status = 'paid'::text)")
        #expect(plan.rootNode.properties["Node Type"] == nil)
        #expect(plan.rootNode.properties["Total Cost"] == nil)
    }

    @Test("Cost fractions are relative to the root total")
    func computesCostFractions() throws {
        let plan = try #require(parser.parse(rawText: estimatedPlan))

        #expect(plan.rootNode.costFraction > 0)
        #expect(plan.rootNode.children.allSatisfy { $0.costFraction >= 0 })
        #expect(plan.rootNode.children[0].costFraction > plan.rootNode.children[1].costFraction)
    }

    @Test("Reads planning and execution time from an ANALYZE plan")
    func parsesAnalyzeTimings() throws {
        let analyzePlan = """
        [
          {
            "Plan": {
              "Node Type": "Seq Scan",
              "Relation Name": "users",
              "Startup Cost": 0.00,
              "Total Cost": 12.50,
              "Plan Rows": 250,
              "Plan Width": 40,
              "Actual Startup Time": 0.015,
              "Actual Total Time": 0.132,
              "Actual Rows": 250,
              "Actual Loops": 1
            },
            "Planning Time": 0.183,
            "Execution Time": 0.201
          }
        ]
        """

        let plan = try #require(parser.parse(rawText: analyzePlan))

        #expect(plan.planningTime == 0.183)
        #expect(plan.executionTime == 0.201)
        #expect(plan.rootNode.actualStartupTime == 0.015)
        #expect(plan.rootNode.actualTotalTime == 0.132)
        #expect(plan.rootNode.actualRows == 250)
        #expect(plan.rootNode.actualLoops == 1)
    }

    @Test("Rejects malformed and non-plan input")
    func rejectsMalformedInput() {
        #expect(parser.parse(rawText: "") == nil)
        #expect(parser.parse(rawText: "not json") == nil)
        #expect(parser.parse(rawText: "{}") == nil)
        #expect(parser.parse(rawText: "[]") == nil)
        #expect(parser.parse(rawText: "[{\"NotAPlan\": {}}]") == nil)
    }

    @Test("A node with no type is labelled rather than dropped")
    func labelsUnknownNodeType() throws {
        let plan = try #require(parser.parse(rawText: "[{\"Plan\": {\"Total Cost\": 1.0}}]"))
        #expect(plan.rootNode.operation == "Unknown")
    }
}
