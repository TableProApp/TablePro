//
//  QueryPlanNodeSummaryTests.swift
//  TableProTests
//
//  Tests the plain-text and spoken renderings of a plan node.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Node Summary")
struct QueryPlanNodeSummaryTests {
    private func makeNode(
        operation: String = "Seq Scan",
        relation: String? = "orders",
        startupCost: Double? = 0.5,
        totalCost: Double? = 12.25,
        rows: Int? = 1_204,
        actualTime: Double? = nil,
        properties: [String: String] = [:]
    ) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: relation,
            schema: nil,
            alias: nil,
            estimatedStartupCost: startupCost,
            estimatedTotalCost: totalCost,
            estimatedRows: rows,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: actualTime,
            actualRows: nil,
            actualLoops: nil,
            properties: properties,
            children: []
        )
    }

    @Test("Copy text starts with the operation and lists what the node reports")
    func buildsCopyText() {
        let text = QueryPlanNodeSummary.text(for: makeNode(properties: ["Filter": "(id > 3)"]))
        let lines = text.components(separatedBy: "\n")

        #expect(lines.first == "Seq Scan")
        #expect(text.contains("orders"))
        #expect(text.contains("0.50..12.25"))
        #expect(text.contains("1204"))
        #expect(text.contains("Filter: (id > 3)"))
    }

    @Test("Copy text omits what the node does not report")
    func omitsMissingValues() {
        let text = QueryPlanNodeSummary.text(
            for: makeNode(relation: nil, startupCost: nil, totalCost: nil, rows: nil)
        )
        #expect(text == "Seq Scan")
    }

    @Test("Hidden properties never reach the copy text")
    func skipsHiddenProperties() {
        let text = QueryPlanNodeSummary.text(for: makeNode(properties: ["Parallel Aware": "true"]))
        #expect(!text.contains("Parallel Aware"))
    }

    @Test("The spoken label names the operation, the relation and the severity")
    func buildsAccessibilityLabel() {
        let label = QueryPlanNodeSummary.accessibilityLabel(for: makeNode())

        #expect(label.hasPrefix("Seq Scan"))
        #expect(label.contains("orders"))
        #expect(label.contains(QueryPlanSeverity.low.accessibilityLabel))
    }

    @Test("Actual timing appears in both renderings when present")
    func includesActualTiming() {
        let node = makeNode(actualTime: 3.25)

        #expect(QueryPlanNodeSummary.text(for: node).contains("3.250"))
        #expect(QueryPlanNodeSummary.accessibilityLabel(for: node).contains("3.250"))
    }
}
