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
        #expect(QueryPlanSeverity.forCostFraction(0) == .low)
        #expect(QueryPlanSeverity.forCostFraction(0.05) == .low)
        #expect(QueryPlanSeverity.forCostFraction(0.06) == .moderate)
        #expect(QueryPlanSeverity.forCostFraction(0.2) == .moderate)
        #expect(QueryPlanSeverity.forCostFraction(0.21) == .high)
        #expect(QueryPlanSeverity.forCostFraction(0.5) == .high)
        #expect(QueryPlanSeverity.forCostFraction(0.51) == .critical)
        #expect(QueryPlanSeverity.forCostFraction(1.0) == .critical)
    }

    @Test("A non-finite or negative fraction is treated as cheap rather than trapping")
    func handlesInvalidFractions() {
        #expect(QueryPlanSeverity.forCostFraction(.nan) == .low)
        #expect(QueryPlanSeverity.forCostFraction(.infinity) == .low)
        #expect(QueryPlanSeverity.forCostFraction(-1) == .low)
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
}
