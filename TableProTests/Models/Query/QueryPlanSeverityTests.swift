//
//  QueryPlanSeverityTests.swift
//  TableProTests
//
//  Tests for classifying a plan node's cost share into a severity.
//

import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Query Plan Severity")
struct QueryPlanSeverityTests {
    @Test("Each band maps to its severity")
    func classifiesBands() {
        #expect(QueryPlanSeverity.forShare(0) == .low)
        #expect(QueryPlanSeverity.forShare(0.05) == .low)
        #expect(QueryPlanSeverity.forShare(0.06) == .moderate)
        #expect(QueryPlanSeverity.forShare(0.2) == .moderate)
        #expect(QueryPlanSeverity.forShare(0.21) == .high)
        #expect(QueryPlanSeverity.forShare(0.5) == .high)
        #expect(QueryPlanSeverity.forShare(0.51) == .critical)
        #expect(QueryPlanSeverity.forShare(1.0) == .critical)
    }

    @Test("A non-finite or negative share is treated as cheap rather than trapping")
    func handlesInvalidShares() {
        #expect(QueryPlanSeverity.forShare(.nan) == .low)
        #expect(QueryPlanSeverity.forShare(.infinity) == .low)
        #expect(QueryPlanSeverity.forShare(-1) == .low)
    }

    /// A share is a part of a whole, so anything above 1 means the caller divided by the wrong
    /// thing. Clamping keeps the badge readable instead of leaving the value to fall through the
    /// `> 0.5` arm and pin the node to Critical without saying why.
    @Test("A share above one is clamped rather than trusted")
    func clampsAnImpossibleShare() {
        #expect(QueryPlanSeverity.forShare(5.626) == .critical)
        #expect(QueryPlanSeverity.forShare(11.828) == .critical)
    }

    @Test("A node whose plan reported no cost has no severity at all")
    func reportsNoSeverityWithoutACost() {
        let node = QueryPlanNode(
            operation: "SCAN Track",
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil, estimatedTotalCost: nil,
            estimatedRows: nil, estimatedWidth: nil,
            actualStartupTime: nil, actualTotalTime: nil,
            actualRows: nil, actualLoops: nil,
            properties: [:],
            children: []
        )

        #expect(node.severity == nil)
        #expect(!QueryPlanNodeSummary.accessibilityLabel(for: node).contains("cost"))
    }

    @Test("Every severity has a distinct glyph")
    func glyphsAreDistinct() {
        let symbols = Set(QueryPlanSeverity.allCases.map(\.symbolName))
        #expect(symbols.count == QueryPlanSeverity.allCases.count)
    }

    @Test("Differentiate without colour drops the hue but keeps the severity")
    func dropsHueWhenAsked() {
        for severity in QueryPlanSeverity.allCases {
            #expect(severity.tint(differentiateWithoutColor: true) == .secondary)
            #expect(severity.tint(differentiateWithoutColor: false) == severity.color)
            #expect(!severity.accessibilityLabel.isEmpty)
        }
    }

    @Test("Hidden property keys are filtered out of the visible set")
    func filtersHiddenProperties() {
        let node = QueryPlanNode(
            operation: "Seq Scan",
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil, estimatedTotalCost: nil,
            estimatedRows: nil, estimatedWidth: nil,
            actualStartupTime: nil, actualTotalTime: nil,
            actualRows: nil, actualLoops: nil,
            properties: [
                "Parallel Aware": "true",
                "Filter": "(id > 3)",
                "Rows Removed by Filter": "0",
                "Sort Key": "id",
            ],
            children: []
        )

        let visible = QueryPlanLabels.visibleProperties(of: node)
        #expect(visible.map(\.key) == ["Filter", "Sort Key"])
    }

    /// PostgreSQL reports `Workers Planned: 2, Workers Launched: 0` when the planner asked for
    /// parallelism and the server had no worker slots left. Dropping the zero left the planned
    /// count on screen unopposed, so a serial plan read as a parallel one.
    @Test("A zero that is the answer is not filtered out as noise")
    func keepsSignificantZeros() {
        let node = QueryPlanNode(
            operation: "Gather",
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil, estimatedTotalCost: nil,
            estimatedRows: nil, estimatedWidth: nil,
            actualStartupTime: nil, actualTotalTime: nil,
            actualRows: nil, actualLoops: nil,
            properties: [
                "Workers Planned": "2",
                "Workers Launched": "0",
                "Rows Removed by Filter": "0",
                "Single Copy": "false",
            ],
            children: []
        )

        let visible = QueryPlanLabels.visibleProperties(of: node)
        #expect(visible.map(\.key) == ["Workers Launched", "Workers Planned"])
    }
}
