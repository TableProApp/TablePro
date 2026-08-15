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

    @Test("Cost fractions stay at zero when the root reports no cost")
    func skipsFractionsWithoutRootCost() {
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

        #expect(plan.rootNode.children.allSatisfy { $0.costFraction == 0 })
    }

    @Test("Cost fractions are relative to the root total")
    func dividesByRootCost() {
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
