//
//  QueryPlanSeverity.swift
//  TablePro
//
//  How expensive a plan node is relative to the whole plan. Kept free of SwiftUI so the
//  thresholds can be tested directly and both plan views classify identically.
//

import Foundation

enum QueryPlanSeverity: CaseIterable {
    case low
    case moderate
    case high
    case critical

    static func forCostFraction(_ fraction: Double) -> QueryPlanSeverity {
        guard fraction.isFinite else { return .low }
        if fraction > 0.5 { return .critical }
        if fraction > 0.2 { return .high }
        if fraction > 0.05 { return .moderate }
        return .low
    }
}

extension QueryPlanNode {
    var severity: QueryPlanSeverity {
        QueryPlanSeverity.forCostFraction(costFraction)
    }
}
