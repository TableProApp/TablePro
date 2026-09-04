//
//  QueryPlanLoopCorrectionTests.swift
//  TableProTests
//
//  A plan reports per-execution averages. Turning them into totals is what a magnitude bar needs
//  and what the raw fields deliberately do not carry.
//
//  The fixtures are verbatim output from a PostgreSQL 17.11 server, not hand-written numbers.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Loop Correction")
struct QueryPlanLoopCorrectionTests {
    private let parser = PostgreSQLPlanParser()

    /// `EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM outerT o JOIN innerT i ON i.id = o.id`
    /// with hash and merge joins disabled, so the inner side runs once per outer row.
    private let nestedLoopPlan = """
    [
      {
        "Plan": {
          "Node Type": "Nested Loop",
          "Join Type": "Inner",
          "Startup Cost": 0.29, "Total Cost": 1162.50,
          "Plan Rows": 500, "Plan Width": 29,
          "Actual Startup Time": 0.011, "Actual Total Time": 0.233,
          "Actual Rows": 500, "Actual Loops": 1,
          "Plans": [
            {
              "Node Type": "Seq Scan", "Relation Name": "outert", "Alias": "o",
              "Startup Cost": 0.00, "Total Cost": 9.00,
              "Plan Rows": 500, "Plan Width": 4,
              "Actual Startup Time": 0.004, "Actual Total Time": 0.016,
              "Actual Rows": 500, "Actual Loops": 1
            },
            {
              "Node Type": "Index Scan", "Relation Name": "innert", "Alias": "i",
              "Startup Cost": 0.29, "Total Cost": 2.30,
              "Plan Rows": 1, "Plan Width": 25,
              "Actual Startup Time": 0.0002, "Actual Total Time": 0.0004,
              "Actual Rows": 1, "Actual Loops": 500
            }
          ]
        },
        "Planning Time": 0.235,
        "Execution Time": 0.259
      }
    ]
    """

    /// The same server with `max_parallel_workers_per_gather = 2`. The workers run at the same
    /// time, so their durations must not be added together.
    private let parallelPlan = """
    [
      {
        "Plan": {
          "Node Type": "Aggregate",
          "Startup Cost": 28194.98, "Total Cost": 28194.99,
          "Plan Rows": 1, "Plan Width": 8,
          "Actual Total Time": 120.701, "Actual Rows": 1, "Actual Loops": 1,
          "Plans": [
            {
              "Node Type": "Gather",
              "Startup Cost": 28194.97, "Total Cost": 28194.98,
              "Plan Rows": 2, "Plan Width": 8,
              "Actual Total Time": 120.697, "Actual Rows": 3, "Actual Loops": 1,
              "Workers Planned": 2, "Workers Launched": 2,
              "Plans": [
                {
                  "Node Type": "Aggregate",
                  "Startup Cost": 28194.97, "Total Cost": 28194.97,
                  "Plan Rows": 1, "Plan Width": 8,
                  "Actual Total Time": 117.691, "Actual Rows": 1, "Actual Loops": 3,
                  "Plans": [
                    {
                      "Node Type": "Seq Scan", "Relation Name": "big",
                      "Startup Cost": 0.00, "Total Cost": 27753.00,
                      "Plan Rows": 76323, "Plan Width": 0,
                      "Actual Total Time": 116.215, "Actual Rows": 76323, "Actual Loops": 3
                    }
                  ]
                }
              ]
            }
          ]
        },
        "Execution Time": 120.728
      }
    ]
    """

    @Test("A node that ran once per outer row is charted on its total, not its average")
    func multipliesByLoops() throws {
        let plan = try #require(parser.parse(rawText: nestedLoopPlan))
        let counts = QueryPlanLoopCorrection.processCounts(in: plan.rootNode)
        let indexScan = try #require(plan.rootNode.children.first { $0.operation == "Index Scan" })

        #expect(indexScan.actualTotalTime == 0.0004)
        #expect(indexScan.actualLoops == 500)
        let total = try #require(indexScan.totalTime(processCount: counts[indexScan.id] ?? 1))
        #expect(abs(total - 0.2) < 0.0001)
        #expect(indexScan.totalActualRows == 500)
    }

    @Test("Workers divide a duration, because they run at the same time")
    func dividesParallelWorkAcrossWorkers() throws {
        let plan = try #require(parser.parse(rawText: parallelPlan))
        let counts = QueryPlanLoopCorrection.processCounts(in: plan.rootNode)

        let gather = try #require(plan.rootNode.children.first)
        let innerAggregate = try #require(gather.children.first)
        let seqScan = try #require(innerAggregate.children.first)

        // The Gather runs once in the leader, so the divisor belongs to what is under it.
        #expect(counts[plan.rootNode.id] == 1)
        #expect(counts[gather.id] == 1)
        #expect(counts[innerAggregate.id] == 3)
        #expect(counts[seqScan.id] == 3)

        let gatherTime = try #require(gather.totalTime(processCount: counts[gather.id] ?? 1))
        #expect(abs(gatherTime - 120.697) < 0.001)

        let scanTime = try #require(seqScan.totalTime(processCount: counts[seqScan.id] ?? 1))
        #expect(abs(scanTime - 116.215) < 0.001)
    }

    @Test("A Gather that launched no workers is corrected as the serial plan it was")
    func ignoresUnstaffedGather() throws {
        let serial = parallelPlan.replacingOccurrences(
            of: "\"Workers Launched\": 2", with: "\"Workers Launched\": 0"
        )
        let plan = try #require(parser.parse(rawText: serial))
        let counts = QueryPlanLoopCorrection.processCounts(in: plan.rootNode)
        let seqScan = try #require(plan.rootNode.children.first?.children.first?.children.first)

        #expect(counts[seqScan.id] == 1)
    }

    @Test("Self times add up to the plan's execution time")
    func selfTimesSumToExecutionTime() throws {
        let plan = try #require(parser.parse(rawText: parallelPlan))
        let index = try #require(QueryPlanMetricIndex(metric: .selfTime, plan: plan))

        var sum = 0.0
        var nodes = [plan.rootNode]
        while let node = nodes.popLast() {
            sum += index.value(for: node) ?? 0
            nodes.append(contentsOf: node.children)
        }

        // The remainder is executor startup, which sits outside the plan tree.
        #expect(abs(sum - 120.701) < 0.001)
        #expect(sum <= (plan.executionTime ?? 0))
    }

    @Test("The raw per-loop fields are left exactly as the database reported them")
    func leavesReportedFieldsAlone() throws {
        let plan = try #require(parser.parse(rawText: nestedLoopPlan))
        let indexScan = try #require(plan.rootNode.children.first { $0.operation == "Index Scan" })

        #expect(indexScan.actualTotalTime == 0.0004)
        #expect(indexScan.actualRows == 1)
    }
}
