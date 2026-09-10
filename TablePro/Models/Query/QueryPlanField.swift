//
//  QueryPlanField.swift
//  TablePro
//
//  The named values a plan node reports, kept as numbers until the moment they are drawn.
//
//  A metric that reaches the view as a string has already lost its locale: a cost of 52000000
//  renders as "52000000.0" beside a summary row that says "52,000,000" for the same number.
//

import Foundation

enum QueryPlanUnit: Hashable, Sendable {
    /// A planner cost. Unitless, and only comparable between two plans from the same server.
    case cost
    /// A row or loop count.
    case count
    /// A duration the plan reported, already in milliseconds.
    case milliseconds
    /// A width in bytes.
    case bytes
}

enum QueryPlanMetric: String, CaseIterable, Hashable, Sendable {
    case estimatedStartupCost
    case estimatedTotalCost
    case estimatedRows
    case estimatedWidth
    case actualStartupTime
    case actualTotalTime
    case actualRows
    case actualLoops

    var title: String {
        switch self {
        case .estimatedStartupCost: return String(localized: "Estimated Startup Cost")
        case .estimatedTotalCost: return String(localized: "Estimated Total Cost")
        case .estimatedRows: return String(localized: "Estimated Rows")
        case .estimatedWidth: return String(localized: "Estimated Width")
        case .actualStartupTime: return String(localized: "Actual Startup Time")
        case .actualTotalTime: return String(localized: "Actual Total Time")
        case .actualRows: return String(localized: "Actual Rows")
        case .actualLoops: return String(localized: "Actual Loops")
        }
    }

    var unit: QueryPlanUnit {
        switch self {
        case .estimatedStartupCost, .estimatedTotalCost: return .cost
        case .estimatedRows, .actualRows, .actualLoops: return .count
        case .estimatedWidth: return .bytes
        case .actualStartupTime, .actualTotalTime: return .milliseconds
        }
    }

    func value(of node: QueryPlanNode) -> Double? {
        switch self {
        case .estimatedStartupCost: return node.estimatedStartupCost
        case .estimatedTotalCost: return node.estimatedTotalCost
        case .estimatedRows: return node.estimatedRows.map(Double.init)
        case .estimatedWidth: return node.estimatedWidth.map(Double.init)
        case .actualStartupTime: return node.actualStartupTime
        case .actualTotalTime: return node.actualTotalTime
        case .actualRows: return node.actualRows.map(Double.init)
        case .actualLoops: return node.actualLoops.map(Double.init)
        }
    }
}

/// Plan-wide numbers, which live on the plan rather than on any one node.
enum QueryPlanSummaryMetric: String, CaseIterable, Hashable, Sendable {
    case totalCost
    case estimatedRows
    case planningTime
    case executionTime
    case nodeCount

    var title: String {
        switch self {
        case .totalCost: return String(localized: "Cost")
        case .estimatedRows: return String(localized: "Estimated rows")
        case .planningTime: return String(localized: "Planning time")
        case .executionTime: return String(localized: "Execution time")
        case .nodeCount: return String(localized: "Node count")
        }
    }

    var unit: QueryPlanUnit {
        switch self {
        case .totalCost: return .cost
        case .estimatedRows, .nodeCount: return .count
        case .planningTime, .executionTime: return .milliseconds
        }
    }
}

enum QueryPlanField: Hashable, Sendable {
    case metric(QueryPlanMetric)
    case summary(QueryPlanSummaryMetric)
    case property(String)

    var title: String {
        switch self {
        case .metric(let metric): return metric.title
        case .summary(let metric): return metric.title
        case .property(let key): return key
        }
    }

    var unit: QueryPlanUnit? {
        switch self {
        case .metric(let metric): return metric.unit
        case .summary(let metric): return metric.unit
        case .property: return nil
        }
    }

    var id: String {
        switch self {
        case .metric(let metric): return "metric.\(metric.rawValue)"
        case .summary(let metric): return "summary.\(metric.rawValue)"
        case .property(let key): return "property.\(key)"
        }
    }

    /// Metrics sort before properties, and metrics keep their declared order rather than an
    /// alphabetical one, so a node reads startup cost then total cost the way the database prints
    /// it.
    var sortOrder: (Int, Int, String) {
        switch self {
        case .summary(let metric):
            return (0, QueryPlanSummaryMetric.allCases.firstIndex(of: metric) ?? 0, metric.rawValue)
        case .metric(let metric):
            return (1, QueryPlanMetric.allCases.firstIndex(of: metric) ?? 0, metric.rawValue)
        case .property(let key):
            return (2, 0, key)
        }
    }
}

enum QueryPlanFieldValue: Hashable, Sendable {
    case number(Double)
    case text(String)
}

struct QueryPlanFieldChange: Identifiable, Hashable, Sendable {
    let field: QueryPlanField
    let before: QueryPlanFieldValue?
    let after: QueryPlanFieldValue?

    var id: String { field.id }

    var hasChange: Bool { before != after }

    /// The signed difference, when both sides are numbers. A property that changed from one word to
    /// another has no delta, only a before and an after.
    var delta: Double? {
        guard case .number(let before)? = before, case .number(let after)? = after else { return nil }
        return after - before
    }

    /// How much larger the current value is, as a multiple of the baseline. Nil when the baseline is
    /// zero, because everything is infinitely larger than nothing and saying so helps nobody.
    var ratio: Double? {
        guard case .number(let before)? = before, case .number(let after)? = after,
              before > 0, before.isFinite, after.isFinite
        else { return nil }
        return after / before
    }
}
