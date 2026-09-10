//
//  QueryPlanBarMetric.swift
//  TablePro
//
//  What the plan outline's magnitude column charts.
//
//  Deliberately not extra cases on `QueryPlanMetric`: that enum is the Compare pane's field
//  vocabulary and `QueryPlanDiff.fields(of:)` walks its `allCases`, so a case added here would
//  appear as a new diffed field on every node of every plan comparison. The two row metrics still
//  take their names and units from it, so a row count is spelled one way everywhere.
//
//  Every metric is exclusive or per-node on purpose. An inclusive metric makes the root the
//  largest bar in every plan, which says nothing about where the work is.
//

import Foundation

enum QueryPlanBarMetric: String, CaseIterable, Identifiable, Sendable {
    case selfCost
    case selfTime
    case estimatedRows
    case actualRows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selfCost: return String(localized: "Self Cost")
        case .selfTime: return String(localized: "Self Time")
        case .estimatedRows: return QueryPlanMetric.estimatedRows.title
        case .actualRows: return QueryPlanMetric.actualRows.title
        }
    }

    var unit: QueryPlanUnit {
        switch self {
        case .selfCost: return .cost
        case .selfTime: return .milliseconds
        case .estimatedRows: return QueryPlanMetric.estimatedRows.unit
        case .actualRows: return QueryPlanMetric.actualRows.unit
        }
    }

    /// Whether the plan's values for this metric sum to a meaningful whole. Self cost and self time
    /// do, so a node's part of that total is its share of the query. Row counts do not, because a
    /// parent re-reports the rows its children produced, so the only honest comparison is against
    /// the largest node.
    var isAdditive: Bool {
        switch self {
        case .selfCost, .selfTime: return true
        case .estimatedRows, .actualRows: return false
        }
    }

    /// How the accessible value phrases a node's weight, which differs because the denominator
    /// differs. Calling a row count a "share" would claim a conserved total that does not exist.
    func emphasisDescription(_ formatted: String) -> String {
        isAdditive
            ? String(format: String(localized: "%@ of the plan"), formatted)
            : String(format: String(localized: "%@ of the largest step"), formatted)
    }
}
