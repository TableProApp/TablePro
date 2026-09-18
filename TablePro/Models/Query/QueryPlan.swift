//
//  QueryPlan.swift
//  TablePro
//
//  Data model for parsed EXPLAIN query plans.
//

import Foundation

/// A single node in an EXPLAIN query plan tree.
struct QueryPlanNode: Identifiable, Sendable {
    let id = UUID()
    let operation: String
    let relation: String?
    let schema: String?
    let alias: String?
    let estimatedStartupCost: Double?
    let estimatedTotalCost: Double?
    let estimatedRows: Int?
    let estimatedWidth: Int?
    let actualStartupTime: Double?
    let actualTotalTime: Double?
    let actualRows: Int?
    let actualLoops: Int?
    let properties: [String: String]
    var children: [QueryPlanNode]

    /// This node's share of the plan's total work (0.0-1.0), set after the tree is built.
    /// Absent when the plan reports no cost anywhere, which is not the same as a share of zero.
    var costFraction: Double?

    /// Exclusive cost (this node only, excluding children).
    var exclusiveCost: Double {
        let childCost = children.reduce(0.0) { $0 + ($1.estimatedTotalCost ?? 0) }
        return max(0, (estimatedTotalCost ?? 0) - childCost)
    }

    /// `startup..total` when the plan reports both, `total` alone when it reports only the total.
    func costRangeText(fractionDigits: Int) -> String? {
        guard let total = estimatedTotalCost else { return nil }
        let number = "%.\(fractionDigits)f"
        guard let startup = estimatedStartupCost else { return String(format: number, total) }
        return String(format: "\(number)..\(number)", startup, total)
    }
}

/// A parsed EXPLAIN query plan.
struct QueryPlan: Sendable {
    var rootNode: QueryPlanNode
    let planningTime: Double?
    let executionTime: Double?
    let rawText: String

    /// Compute each node's share of the plan's total work.
    ///
    /// The denominator is the sum of every node's exclusive cost, not the root's total cost. The
    /// root's total is not an upper bound on the work below it: PostgreSQL prices a `Limit` far
    /// below its child on purpose, so dividing by it produced shares above 1 (measured at 5.6 on a
    /// plain `ORDER BY ... LIMIT 2` and 11.8 under a merge join) and `QueryPlanSeverity` has no arm
    /// above `.critical` to catch them. Exclusive costs sum to the real total, so a share of it is
    /// bounded and adds up to 1, and it is identical to the old value wherever that was already
    /// in range.
    ///
    /// A plan that reports no cost anywhere leaves every fraction nil, so "nothing was reported"
    /// stays distinguishable from "this node is free".
    mutating func computeCostFractions() {
        let total = Self.totalExclusiveCost(of: rootNode)
        guard total > 0 else { return }
        assignFractions(node: &rootNode, totalCost: total)
    }

    private static func totalExclusiveCost(of node: QueryPlanNode) -> Double {
        node.children.reduce(node.exclusiveCost) { $0 + totalExclusiveCost(of: $1) }
    }

    /// Whether any node in the plan satisfies a predicate, for deciding what there is to show.
    func contains(where predicate: (QueryPlanNode) -> Bool) -> Bool {
        Self.contains(node: rootNode, where: predicate)
    }

    private static func contains(node: QueryPlanNode, where predicate: (QueryPlanNode) -> Bool) -> Bool {
        predicate(node) || node.children.contains { contains(node: $0, where: predicate) }
    }

    private func assignFractions(node: inout QueryPlanNode, totalCost: Double) {
        node.costFraction = node.exclusiveCost / totalCost
        for i in node.children.indices {
            assignFractions(node: &node.children[i], totalCost: totalCost)
        }
    }
}
