//
//  QueryPlanDiagramLayout.swift
//  TablePro
//
//  Geometry for the EXPLAIN plan diagram: one row per tree depth, children centered
//  under their parent.
//

import CoreGraphics
import Foundation

enum QueryPlanDiagramMetrics {
    static let nodeWidth: CGFloat = 200
    static let nodeMinHeight: CGFloat = 50
    static let horizontalSpacing: CGFloat = 24
    static let verticalSpacing: CGFloat = 40
    static let nodePadding: CGFloat = 8
    static let cornerRadius: CGFloat = 6
    static let arrowHeadSize: CGFloat = 6
}

struct QueryPlanDiagramLayout {
    struct Node: Identifiable {
        let id: UUID
        let node: QueryPlanNode
        let rect: CGRect
        let parentId: UUID?
    }

    /// A parent-to-child connector, as geometry rather than as a drawn path, so the live diagram
    /// and the export render the same arrows from one source and a test can measure them.
    struct Arrow: Identifiable {
        let id: UUID
        let start: CGPoint
        let end: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let head: [CGPoint]
    }

    let nodes: [Node]
    let canvasSize: CGSize
    let arrows: [Arrow]

    init(root: QueryPlanNode) {
        let rowOffsets = Self.rowOffsets(root)
        let nodes = Self.position(root, depth: 0, xOffset: 0, parentId: nil, rowOffsets: rowOffsets)
        self.nodes = nodes
        canvasSize = Self.canvasSize(of: nodes)
        arrows = Self.arrows(of: nodes)
    }

    // MARK: - Arrows

    private static func arrows(of nodes: [Node]) -> [Arrow] {
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let headSize = QueryPlanDiagramMetrics.arrowHeadSize

        return nodes.compactMap { node -> Arrow? in
            guard let parentId = node.parentId, let parent = nodeMap[parentId] else { return nil }

            let start = CGPoint(x: parent.rect.midX, y: parent.rect.maxY)
            let end = CGPoint(x: node.rect.midX, y: node.rect.minY)
            let midY = (start.y + end.y) / 2

            return Arrow(
                id: node.id,
                start: start,
                end: end,
                control1: CGPoint(x: start.x, y: midY),
                control2: CGPoint(x: end.x, y: midY),
                head: [
                    end,
                    CGPoint(x: end.x - headSize, y: end.y - headSize),
                    CGPoint(x: end.x + headSize, y: end.y - headSize)
                ]
            )
        }
    }

    // MARK: - Rows

    /// The top edge of every depth, stacked by the tallest node in each row so siblings never
    /// drift apart and a child never lands inside its parent.
    private static func rowOffsets(_ root: QueryPlanNode) -> [CGFloat] {
        var heights: [CGFloat] = []

        func measure(_ node: QueryPlanNode, depth: Int) {
            let height = nodeHeight(node)
            if depth < heights.count {
                heights[depth] = max(heights[depth], height)
            } else {
                heights.append(height)
            }
            for child in node.children { measure(child, depth: depth + 1) }
        }
        measure(root, depth: 0)

        var offsets: [CGFloat] = []
        var top = QueryPlanDiagramMetrics.verticalSpacing
        for height in heights {
            offsets.append(top)
            top += height + QueryPlanDiagramMetrics.verticalSpacing
        }
        return offsets
    }

    private static func nodeHeight(_ node: QueryPlanNode) -> CGFloat {
        var height: CGFloat = 18
        if node.relation != nil { height += 14 }
        if node.estimatedTotalCost != nil || node.estimatedRows != nil { height += 12 }
        if node.actualTotalTime != nil { height += 12 }
        return max(
            QueryPlanDiagramMetrics.nodeMinHeight,
            height + QueryPlanDiagramMetrics.nodePadding * 2
        )
    }

    // MARK: - Placement

    private static func position(
        _ node: QueryPlanNode,
        depth: Int,
        xOffset: CGFloat,
        parentId: UUID?,
        rowOffsets: [CGFloat]
    ) -> [Node] {
        let size = CGSize(width: QueryPlanDiagramMetrics.nodeWidth, height: nodeHeight(node))
        let top = depth < rowOffsets.count ? rowOffsets[depth] : QueryPlanDiagramMetrics.verticalSpacing

        guard !node.children.isEmpty else {
            let rect = CGRect(
                origin: CGPoint(x: xOffset + QueryPlanDiagramMetrics.horizontalSpacing, y: top),
                size: size
            )
            return [Node(id: node.id, node: node, rect: rect, parentId: parentId)]
        }

        var childPositions: [Node] = []
        var currentX = xOffset
        for child in node.children {
            let childNodes = position(
                child, depth: depth + 1, xOffset: currentX, parentId: node.id, rowOffsets: rowOffsets
            )
            currentX += subtreeWidth(childNodes) + QueryPlanDiagramMetrics.horizontalSpacing
            childPositions.append(contentsOf: childNodes)
        }

        let firstChildX = childPositions.first { $0.parentId == node.id }?.rect.midX ?? xOffset
        let lastChildX = childPositions.last { $0.parentId == node.id }?.rect.midX ?? xOffset
        let centerX = (firstChildX + lastChildX) / 2

        let rect = CGRect(
            origin: CGPoint(x: centerX - QueryPlanDiagramMetrics.nodeWidth / 2, y: top),
            size: size
        )
        return [Node(id: node.id, node: node, rect: rect, parentId: parentId)] + childPositions
    }

    private static func subtreeWidth(_ nodes: [Node]) -> CGFloat {
        guard let minX = nodes.map({ $0.rect.minX }).min(),
              let maxX = nodes.map({ $0.rect.maxX }).max()
        else { return QueryPlanDiagramMetrics.nodeWidth }
        return maxX - minX
    }

    private static func canvasSize(of nodes: [Node]) -> CGSize {
        let maxX = nodes.map { $0.rect.maxX }.max() ?? 400
        let maxY = nodes.map { $0.rect.maxY }.max() ?? 300
        return CGSize(
            width: maxX + QueryPlanDiagramMetrics.horizontalSpacing * 2,
            height: maxY + QueryPlanDiagramMetrics.verticalSpacing * 2
        )
    }
}
