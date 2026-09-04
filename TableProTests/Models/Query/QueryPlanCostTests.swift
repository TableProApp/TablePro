//
//  QueryPlanCostTests.swift
//  TableProTests
//
//  Tests for cost text and cost fractions on a parsed query plan.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Cost")
struct QueryPlanCostTests {
    private func node(
        _ operation: String,
        startupCost: Double? = nil,
        totalCost: Double? = nil,
        children: [QueryPlanNode] = []
    ) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: nil,
            schema: nil,
            alias: nil,
            estimatedStartupCost: startupCost,
            estimatedTotalCost: totalCost,
            estimatedRows: nil,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: nil,
            actualLoops: nil,
            properties: [:],
            children: children
        )
    }

    @Test("A plan with only a total cost still shows it")
    func showsTotalOnlyCost() {
        let totalOnly = node("Table scan", totalCost: 3.5)
        #expect(totalOnly.costRangeText(fractionDigits: 1) == "3.5")
        #expect(totalOnly.costRangeText(fractionDigits: 2) == "3.50")
    }

    @Test("A plan with both costs shows the range")
    func showsCostRange() {
        let range = node("Seq Scan", startupCost: 0.5, totalCost: 12.25)
        #expect(range.costRangeText(fractionDigits: 1) == "0.5..12.2")
        #expect(range.costRangeText(fractionDigits: 2) == "0.50..12.25")
    }

    @Test("A plan with no cost shows nothing")
    func hidesMissingCost() {
        #expect(node("Hash").costRangeText(fractionDigits: 2) == nil)
    }

    @Test("Cost fractions are absent when no node reports a cost")
    func skipsFractionsWithoutAnyCost() {
        var plan = QueryPlan(
            rootNode: node("Query Plan", children: [node("Table scan"), node("Table scan")]),
            planningTime: nil,
            executionTime: nil,
            rawText: ""
        )
        plan.computeCostFractions()

        #expect(plan.rootNode.costFraction == nil)
        #expect(plan.rootNode.children.allSatisfy { $0.costFraction == nil })
        #expect(plan.rootNode.severity == nil)
    }

    /// The costs a plan reports do not stop counting because the root did not repeat them. This is
    /// the MySQL JSON shape, where the wrapper block carries no cost of its own.
    @Test("Costs below a costless root are still shares of the plan")
    func dividesCostsUnderACostlessRoot() {
        var plan = QueryPlan(
            rootNode: node("Query Plan", children: [
                node("Table scan", totalCost: 1),
                node("Table scan", totalCost: 1),
            ]),
            planningTime: nil,
            executionTime: nil,
            rawText: ""
        )
        plan.computeCostFractions()

        #expect(plan.rootNode.children.allSatisfy { $0.costFraction == 0.5 })
    }

    /// Measured against PostgreSQL 17: `EXPLAIN SELECT * FROM big ORDER BY id LIMIT 2` prices the
    /// Limit at 34370.92 while the Gather Merge below it costs 228828.63. Dividing by the root's
    /// total reported the Gather Merge as 562% of the plan, and every node above 50% is Critical,
    /// so a Seq Scan doing 11% of the work wore the same red badge as the node doing 85%.
    @Test("A root priced below its subtree still yields shares inside 0...1")
    func boundsSharesUnderALimit() {
        var plan = QueryPlan(
            rootNode: node("Limit", totalCost: 34370.92, children: [
                node("Gather Merge", totalCost: 228828.63, children: [
                    node("Sort", totalCost: 35454.00, children: [
                        node("Seq Scan", totalCost: 25037.33),
                    ]),
                ]),
            ]),
            planningTime: nil,
            executionTime: nil,
            rawText: ""
        )
        plan.computeCostFractions()

        let limit = plan.rootNode
        let gatherMerge = limit.children[0]
        let sort = gatherMerge.children[0]
        let seqScan = sort.children[0]

        for node in [limit, gatherMerge, sort, seqScan] {
            let fraction = node.costFraction ?? -1
            #expect((0 ... 1).contains(fraction))
        }

        #expect(abs((gatherMerge.costFraction ?? 0) - 0.845) < 0.001)
        #expect(abs((seqScan.costFraction ?? 0) - 0.109) < 0.001)
        #expect(gatherMerge.severity == .critical)
        #expect(seqScan.severity == .moderate)
        #expect(sort.severity == .low)
    }

    /// The clamp that keeps one branch honest must not quietly shrink another. The Limit's own
    /// exclusive cost clamps to zero; the expensive sibling below must keep its share.
    @Test("A clamped branch does not dilute an expensive one elsewhere")
    func keepsAnExpensiveBranchAfterClamping() {
        var plan = QueryPlan(
            rootNode: node("Append", totalCost: 100, children: [
                node("Limit", totalCost: 10, children: [node("Cheap Scan", totalCost: 40)]),
                node("Expensive Scan", totalCost: 360),
            ]),
            planningTime: nil,
            executionTime: nil,
            rawText: ""
        )
        plan.computeCostFractions()

        let expensive = plan.rootNode.children[1]
        #expect(plan.rootNode.children[0].costFraction == 0)
        #expect(abs((expensive.costFraction ?? 0) - 0.9) < 0.0001)
        #expect(expensive.severity == .critical)
    }

    @Test("Cost fractions are a node's share of the plan's total work")
    func dividesByTotalExclusiveCost() {
        var plan = QueryPlan(
            rootNode: node("Nested loop", totalCost: 10, children: [
                node("Table scan", totalCost: 6),
                node("Table scan", totalCost: 2),
            ]),
            planningTime: nil,
            executionTime: nil,
            rawText: ""
        )
        plan.computeCostFractions()

        #expect(plan.rootNode.costFraction == 0.2)
        #expect(plan.rootNode.children[0].costFraction == 0.6)
        #expect(plan.rootNode.children[1].costFraction == 0.2)
    }

    @Test("A synthetic root totals the costs of the plans it wraps")
    func sumsWrappedRootCosts() {
        let roots = [node("Table scan", totalCost: 3), node("Table scan", totalCost: 1)]
        let wrapped = QueryPlanTreeBuilder.root(from: roots)

        #expect(wrapped?.operation == "Query Plan")
        #expect(wrapped?.estimatedTotalCost == 4)
        #expect(wrapped?.exclusiveCost == 0)
    }

    @Test("A synthetic root over costless plans reports no cost")
    func leavesCostlessWrappedRootsAlone() {
        let wrapped = QueryPlanTreeBuilder.root(from: [node("Scan"), node("Scan")])
        #expect(wrapped?.estimatedTotalCost == nil)
    }

    @Test("A single root is returned unwrapped")
    func returnsSingleRootUnwrapped() {
        #expect(QueryPlanTreeBuilder.root(from: [node("Table scan")])?.operation == "Table scan")
        #expect(QueryPlanTreeBuilder.root(from: []) == nil)
    }
}
