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

    /// `share` is a node's part of a plan-wide total, so it belongs in 0...1. A value outside that
    /// range means the caller divided by the wrong thing, and the clamp keeps the badge readable
    /// rather than pinning every node to `.critical`.
    static func forShare(_ share: Double) -> QueryPlanSeverity {
        guard share.isFinite else { return .low }
        let bounded = min(max(share, 0), 1)
        if bounded > 0.5 { return .critical }
        if bounded > 0.2 { return .high }
        if bounded > 0.05 { return .moderate }
        return .low
    }
}

extension QueryPlanNode {
    /// Nil when the plan reported no cost at all. Four of the seven plan formats the app parses
    /// report none, and calling those nodes "low cost" claims a measurement nobody made.
    var severity: QueryPlanSeverity? {
        costFraction.map(QueryPlanSeverity.forShare)
    }
}
