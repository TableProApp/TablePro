//
//  QueryPlanTreeBuilder.swift
//  TablePro
//
//  Shared tree assembly for the text-based EXPLAIN parsers.
//

import Foundation

enum QueryPlanTreeBuilder {
    /// Builds a forest from a pre-order list where each element carries its own depth.
    /// An element belongs to the closest preceding element with a smaller depth.
    static func forest<Element>(
        from elements: [Element],
        depth: (Element) -> Int,
        makeNode: (Element, [QueryPlanNode]) -> QueryPlanNode
    ) -> [QueryPlanNode] {
        var index = 0

        func build(parentDepth: Int) -> [QueryPlanNode] {
            var nodes: [QueryPlanNode] = []
            while index < elements.count {
                let element = elements[index]
                let elementDepth = depth(element)
                if elementDepth <= parentDepth { break }
                index += 1
                nodes.append(makeNode(element, build(parentDepth: elementDepth)))
            }
            return nodes
        }

        return build(parentDepth: -1)
    }

    /// Returns the single root, or wraps several roots in one synthetic node whose cost is the
    /// sum of the roots that report one, so cost fractions stay relative to a real total.
    static func root(from roots: [QueryPlanNode]) -> QueryPlanNode? {
        if roots.count == 1 { return roots[0] }
        guard !roots.isEmpty else { return nil }

        let costs = roots.compactMap(\.estimatedTotalCost)
        return QueryPlanNode(
            operation: "Query Plan",
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: costs.isEmpty ? nil : costs.reduce(0, +),
            estimatedRows: nil, estimatedWidth: nil,
            actualStartupTime: nil, actualTotalTime: nil,
            actualRows: nil, actualLoops: nil,
            properties: [:],
            children: roots
        )
    }
}
