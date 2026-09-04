//
//  QueryPlanMetricIndex.swift
//  TablePro
//
//  One metric's value for every node of a plan, resolved once so a cell never walks the tree.
//
//  Two denominators, because the bar answers two questions at once. Its length is the value over
//  the largest node's, so the biggest step fills the track and the rest are read against it, which
//  is what pev2 and Tabularis both do and what "compare these nodes" asks for. Its colour comes
//  from `emphasis`, which for an additive metric is the share of the whole plan, so a step that is
//  90% of the query looks alarming even in a plan where two steps are nearly equal.
//

import Foundation

struct QueryPlanMetricIndex: Sendable {
    let metric: QueryPlanBarMetric

    private let values: [UUID: Double]
    private let maximum: Double
    private let total: Double

    /// Nil when no node in the plan reports this metric, which is the difference between a column
    /// with nothing to draw and a column of empty bars implying zero.
    init?(metric: QueryPlanBarMetric, plan: QueryPlan) {
        let values = Self.values(of: metric, in: plan.rootNode)
        guard !values.isEmpty else { return nil }

        self.metric = metric
        self.values = values
        maximum = values.values.max() ?? 0
        total = values.values.reduce(0, +)
    }

    func value(for node: QueryPlanNode) -> Double? {
        values[node.id]
    }

    /// The bar's length, as a part of the track. Zero stays zero so a node that genuinely did no
    /// work draws nothing; the caller floors a small positive value so it stays visible.
    func fraction(for node: QueryPlanNode) -> Double? {
        guard let value = values[node.id], maximum > 0 else { return nil }
        return min(max(value / maximum, 0), 1)
    }

    /// The bar's weight, which drives its colour.
    func emphasis(for node: QueryPlanNode) -> Double? {
        guard let value = values[node.id] else { return nil }
        let denominator = metric.isAdditive ? total : maximum
        guard denominator > 0 else { return nil }
        return min(max(value / denominator, 0), 1)
    }

    /// Only an additive metric has a severity. `QueryPlanSeverity`'s bands mean "this much of the
    /// plan", and a row count is not a part of any whole: a plan that passes 500 rows through every
    /// step would paint every bar critical red on the strength of them all being the maximum. Row
    /// bars carry their meaning in their length and take a neutral tint.
    func severity(for node: QueryPlanNode) -> QueryPlanSeverity? {
        guard metric.isAdditive else { return nil }
        return emphasis(for: node).map(QueryPlanSeverity.forShare)
    }

    /// The metrics this plan can actually chart, in declaration order. Resolved per plan rather
    /// than per engine: the same PostgreSQL connection reports timings under ANALYZE and none
    /// without it.
    static func availableMetrics(in plan: QueryPlan) -> [QueryPlanBarMetric] {
        QueryPlanBarMetric.allCases.filter { !values(of: $0, in: plan.rootNode).isEmpty }
    }

    /// Timings are the truth when a plan measured them, and estimates only stand in when it did
    /// not. A plan that reports neither falls back to whatever it does report.
    static func defaultMetric(among available: [QueryPlanBarMetric]) -> QueryPlanBarMetric? {
        for preferred in [QueryPlanBarMetric.selfTime, .selfCost] where available.contains(preferred) {
            return preferred
        }
        return available.first
    }

    // MARK: - Values

    private static func values(of metric: QueryPlanBarMetric, in root: QueryPlanNode) -> [UUID: Double] {
        var values: [UUID: Double] = [:]
        let processCounts = metric == .selfTime ? QueryPlanLoopCorrection.processCounts(in: root) : [:]
        collect(metric: metric, node: root, processCounts: processCounts, into: &values)
        return values
    }

    private static func collect(
        metric: QueryPlanBarMetric,
        node: QueryPlanNode,
        processCounts: [UUID: Int],
        into values: inout [UUID: Double]
    ) {
        if let value = value(of: metric, node: node, processCounts: processCounts) {
            values[node.id] = value
        }
        for child in node.children {
            collect(metric: metric, node: child, processCounts: processCounts, into: &values)
        }
    }

    private static func value(
        of metric: QueryPlanBarMetric,
        node: QueryPlanNode,
        processCounts: [UUID: Int]
    ) -> Double? {
        switch metric {
        case .selfCost:
            guard node.estimatedTotalCost != nil else { return nil }
            return node.exclusiveCost
        case .selfTime:
            return selfTime(of: node, processCounts: processCounts)
        case .estimatedRows:
            return node.estimatedRows.map(Double.init)
        case .actualRows:
            return node.totalActualRows.map(Double.init)
        }
    }

    /// A child that reported no time contributes nothing rather than voiding the parent, so one
    /// "never executed" branch cannot make its parent look like it did all the work.
    private static func selfTime(of node: QueryPlanNode, processCounts: [UUID: Int]) -> Double? {
        guard let own = node.totalTime(processCount: processCounts[node.id] ?? 1) else { return nil }
        let childTime = node.children.reduce(0.0) { running, child in
            running + (child.totalTime(processCount: processCounts[child.id] ?? 1) ?? 0)
        }
        return max(0, own - childTime)
    }
}
