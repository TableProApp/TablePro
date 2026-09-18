//
//  QueryPlanLoopCorrection.swift
//  TablePro
//
//  Turns the per-execution averages a plan reports into the totals a comparison needs.
//
//  PostgreSQL: "the actual time and rows values shown are averages per-execution ... Multiply by
//  the loops value to get the total time actually spent in the node." MySQL's TREE format reports
//  the same way. An inner index scan measured at 0.000ms over 500 loops is not free, and a bar
//  drawn from the raw figure says it is.
//
//  Under a Gather the loop count is the number of processes that ran the node, and those run at
//  the same time, so their durations do not add up in wall-clock terms. Dividing by the worker
//  count undoes that. The divisor belongs to the Gather's descendants and not to the Gather
//  itself, which runs once in the leader: applying it to the Gather too reported 40.2ms for a node
//  measured at 120.7ms. With it applied to descendants only, the exclusive durations of a plan sum
//  to its execution time, which is what makes self time an additive metric.
//

import Foundation

enum QueryPlanLoopCorrection {
    /// How many processes ran each node, keyed by node id: 1 everywhere outside a Gather, and the
    /// launched worker count plus the leader beneath one.
    static func processCounts(in root: QueryPlanNode) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        assign(node: root, inherited: 1, into: &counts)
        return counts
    }

    private static func assign(node: QueryPlanNode, inherited: Int, into counts: inout [UUID: Int]) {
        counts[node.id] = inherited
        let below = childProcessCount(of: node, inherited: inherited)
        for child in node.children {
            assign(node: child, inherited: below, into: &counts)
        }
    }

    /// A nested Gather keeps the outer count when it launched no workers of its own, so a plan that
    /// asked for parallelism and got none is corrected as the serial plan it actually was.
    private static func childProcessCount(of node: QueryPlanNode, inherited: Int) -> Int {
        guard node.operation.hasPrefix("Gather") else { return inherited }
        guard let launched = node.properties["Workers Launched"].flatMap(Int.init), launched > 0 else {
            return inherited
        }
        return launched + 1
    }
}

extension QueryPlanNode {
    /// Total time spent in this node and everything under it, corrected for loops and workers.
    func totalTime(processCount: Int) -> Double? {
        guard let perLoop = actualTotalTime else { return nil }
        let loops = Double(max(actualLoops ?? 1, 1))
        return perLoop * loops / Double(max(processCount, 1))
    }

    /// Total rows this node produced. Workers do not divide a row count: every worker's rows reach
    /// the Gather, so the loops multiplier stands on its own.
    var totalActualRows: Int? {
        guard let perLoop = actualRows else { return nil }
        return perLoop * max(actualLoops ?? 1, 1)
    }
}
