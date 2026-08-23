//
//  QueryPlanDiagramLayoutTests.swift
//  TableProTests
//
//  Tests that the plan diagram lays out one row per depth without overlapping boxes.
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Diagram Layout")
struct QueryPlanDiagramLayoutTests {
    private func node(
        _ operation: String,
        relation: String? = nil,
        cost: Double? = nil,
        rows: Int? = nil,
        actualTime: Double? = nil,
        children: [QueryPlanNode] = []
    ) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: relation,
            schema: nil,
            alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: cost,
            estimatedRows: rows,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: actualTime,
            actualRows: nil,
            actualLoops: nil,
            properties: [:],
            children: children
        )
    }

    /// A bare node is the shortest box, a node with a relation, cost and timing the tallest.
    private func makeMixedHeightPlan() -> QueryPlanNode {
        node(
            "Nested loop inner join",
            cost: 12,
            rows: 40,
            actualTime: 3.5,
            children: [
                node("Hash", children: [
                    node("Table scan", relation: "t1", cost: 3, rows: 5, actualTime: 0.5),
                ]),
                node("Table scan", relation: "t2", cost: 4, rows: 9, actualTime: 0.9, children: [
                    node("Filter"),
                ]),
            ]
        )
    }

    @Test("Nodes at the same depth share one row")
    func alignsSiblingRows() {
        let plan = makeMixedHeightPlan()
        let layout = QueryPlanDiagramLayout(root: plan)
        let depths = depthByNodeId(plan, depth: 0)

        var topsByDepth: [Int: Set<CGFloat>] = [:]
        for positioned in layout.nodes {
            guard let depth = depths[positioned.id] else { continue }
            topsByDepth[depth, default: []].insert(positioned.rect.minY)
        }

        #expect(topsByDepth.count == 3)
        for (_, tops) in topsByDepth {
            #expect(tops.count == 1)
        }
    }

    @Test("A child never overlaps its parent")
    func keepsChildrenBelowParents() {
        let layout = QueryPlanDiagramLayout(root: makeMixedHeightPlan())
        let byId = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })

        for positioned in layout.nodes {
            guard let parentId = positioned.parentId, let parent = byId[parentId] else { continue }
            #expect(positioned.rect.minY >= parent.rect.maxY)
        }
    }

    @Test("Rows are separated by the standard spacing")
    func stacksRowsByTallestNode() {
        let plan = makeMixedHeightPlan()
        let layout = QueryPlanDiagramLayout(root: plan)
        let depths = depthByNodeId(plan, depth: 0)

        let firstRowTop = layout.nodes.first { depths[$0.id] == 0 }?.rect.minY
        let firstRowBottom = layout.nodes.filter { depths[$0.id] == 0 }.map { $0.rect.maxY }.max()
        let secondRowTop = layout.nodes.first { depths[$0.id] == 1 }?.rect.minY

        #expect(firstRowTop == 40)
        #expect(secondRowTop == (firstRowBottom ?? 0) + 40)
    }

    @Test("Canvas covers every node")
    func canvasCoversAllNodes() {
        let layout = QueryPlanDiagramLayout(root: makeMixedHeightPlan())
        let maxX = layout.nodes.map { $0.rect.maxX }.max() ?? 0
        let maxY = layout.nodes.map { $0.rect.maxY }.max() ?? 0

        #expect(layout.canvasSize.width > maxX)
        #expect(layout.canvasSize.height > maxY)
    }

    @Test("Every node in the tree is positioned once")
    func positionsEveryNode() {
        let layout = QueryPlanDiagramLayout(root: makeMixedHeightPlan())
        #expect(layout.nodes.count == 5)
        #expect(Set(layout.nodes.map(\.id)).count == 5)
        #expect(layout.nodes.filter { $0.parentId == nil }.count == 1)
    }

    private func depthByNodeId(_ node: QueryPlanNode, depth: Int) -> [UUID: Int] {
        var result = [node.id: depth]
        for child in node.children {
            result.merge(depthByNodeId(child, depth: depth + 1)) { current, _ in current }
        }
        return result
    }
}
