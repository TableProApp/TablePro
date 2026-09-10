//
//  ERDiagramSelfReferenceTests.swift
//  TableProTests
//
//  A table that references itself used to be routed from its left border to its own right border,
//  so the curve and both cardinality markers were painted inside the node and then covered by the
//  node's own opaque fill. These pin the loop outside the body.
//

import AppKit
@testable import TablePro
import Testing

/// Smallest possible node (one column), a mid-sized one, and a very tall one.
private let selfLoopNodeHeights: [CGFloat] = [58, 212, 916]

@Suite("ER diagram self-referencing relationships")
@MainActor
struct ERDiagramSelfReferenceTests {

    private func rect(height: CGFloat) -> CGRect {
        CGRect(x: 400, y: 300, width: ERDiagramLayout.nodeWidth, height: height)
    }

    private func curvePoints(_ loop: ERDiagramEdgeRenderer.SelfLoop, samples: Int = 401) -> [CGPoint] {
        (0...samples).map { step in
            let t = CGFloat(step) / CGFloat(samples)
            let u = 1 - t
            let x = u * u * u * loop.source.x
                + 3 * u * u * t * loop.sourceControl.x
                + 3 * u * t * t * loop.destinationControl.x
                + t * t * t * loop.destination.x
            let y = u * u * u * loop.source.y
                + 3 * u * u * t * loop.sourceControl.y
                + 3 * u * t * t * loop.destinationControl.y
                + t * t * t * loop.destination.y
            return CGPoint(x: x, y: y)
        }
    }

    @Test("The loop never enters the table it belongs to", arguments: selfLoopNodeHeights)
    func loopStaysOutsideTheNode(height: CGFloat) {
        let node = rect(height: height)
        let loop = ERDiagramEdgeRenderer.selfLoop(in: node, index: 0)
        let body = node.insetBy(dx: 0.5, dy: 0.5)

        #expect(curvePoints(loop).allSatisfy { !body.contains($0) })
    }

    @Test("Both ports sit on the trailing edge, spread far enough apart for two markers")
    func portsAreOnTheTrailingEdge() {
        for height in selfLoopNodeHeights {
            let node = rect(height: height)
            let loop = ERDiagramEdgeRenderer.selfLoop(in: node, index: 0)

            #expect(loop.source.x == node.maxX)
            #expect(loop.destination.x == node.maxX)
            #expect(loop.source.y > loop.destination.y)
            #expect(abs(loop.source.y - loop.destination.y) >= 28)
            #expect(node.insetBy(dx: 0, dy: -1).contains(CGPoint(x: node.maxX - 1, y: loop.source.y)))
        }
    }

    /// The crow's foot and the one-bar are drawn from a port toward a control point, so an inward
    /// control point would put both markers inside the table.
    @Test("Both cardinality markers point away from the table")
    func markersPointAway() {
        let loop = ERDiagramEdgeRenderer.selfLoop(in: rect(height: 212), index: 0)

        #expect(atan2(loop.sourceControl.y - loop.source.y, loop.sourceControl.x - loop.source.x) == 0)
        #expect(atan2(loop.destinationControl.y - loop.destination.y, loop.destinationControl.x - loop.destination.x) == 0)
    }

    @Test("A second self-referencing key nests outside the first")
    func loopsNest() {
        let node = rect(height: 212)
        let first = ERDiagramEdgeRenderer.selfLoop(in: node, index: 0)
        let second = ERDiagramEdgeRenderer.selfLoop(in: node, index: 1)

        #expect(second.sourceControl.x > first.sourceControl.x)
        #expect(second.source.y > first.source.y)
        #expect(second.destination.y < first.destination.y)
        #expect(curvePoints(second).allSatisfy { !node.insetBy(dx: 0.5, dy: 0.5).contains($0) })
    }

    /// The packer leaves `horizontalGap` to the right of a node and never widens it for a self
    /// loop, so a first loop has to fit inside that gap.
    @Test("The first loop's bulge fits the gap the layout leaves beside a table")
    func bulgeFitsTheColumnGap() {
        for height in selfLoopNodeHeights {
            let node = rect(height: height)
            let loop = ERDiagramEdgeRenderer.selfLoop(in: node, index: 0)
            let bulge = (curvePoints(loop).map(\.x).max() ?? node.maxX) - node.maxX

            #expect(bulge > 0)
            #expect(bulge < ERDiagramLayout.horizontalGap)
        }
    }

    /// The export crops to the drawn content, so a loop the crop does not know about loses its
    /// apex in the PNG and on the clipboard.
    @Test("The drawn bounds reach past the table, far enough for the loop and its markers")
    func drawnBoundsCoverTheLoop() {
        let table = node("employees", columns: [column("id", primaryKey: true), column("manager_id", foreignKey: true)])
        let nodeRect = CGRect(x: 60, y: 60, width: ERDiagramLayout.nodeWidth, height: 212)
        let scene = ERDiagramScene(
            nodes: [table],
            edges: [selfEdge()],
            nodeRects: [table.id: nodeRect],
            nodeIndex: ["employees": table.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: CGSize(width: 800, height: 600)
        )

        let bounds = ERDiagramSceneRenderer.drawnBounds(of: scene)
        let loop = ERDiagramEdgeRenderer.selfLoop(in: nodeRect, index: 0)
        let apex = nodeRect.maxX + (loop.sourceControl.x - nodeRect.maxX) * 0.75

        #expect(bounds.contains(nodeRect))
        #expect(bounds.maxX > apex)
    }

    /// The canvas the scroll view can reach is the node bounds plus a fixed padding, so a nested
    /// loop has to stay inside that padding or it cannot be scrolled to.
    @Test("A nested loop never reaches past the canvas padding")
    func nestedLoopsStayOnTheCanvas() {
        let nodeRect = CGRect(x: 60, y: 60, width: ERDiagramLayout.nodeWidth, height: 916)

        for index in 0..<8 {
            let bulge = ERDiagramEdgeRenderer.selfLoopBounds(in: nodeRect, index: index).maxX - nodeRect.maxX
            #expect(bulge < 80)
        }
    }

    private func selfEdge() -> EREdge {
        EREdge(
            id: UUID(),
            fkName: "fk_manager",
            fromTable: "employees",
            fromColumn: "manager_id",
            toTable: "employees",
            toColumn: "id",
            cardinality: .zeroOrManyToOne
        )
    }

    private func column(_ name: String, primaryKey: Bool = false, foreignKey: Bool = false) -> ERColumnDisplay {
        ERColumnDisplay(
            id: "employees.\(name)",
            name: name,
            dataType: "integer",
            isPrimaryKey: primaryKey,
            isForeignKey: foreignKey,
            isNullable: !primaryKey
        )
    }

    private func node(_ name: String, columns: [ERColumnDisplay]) -> ERTableNode {
        ERTableNode(id: UUID(), tableName: name, columns: columns, displayColumns: columns, clusterId: nil)
    }

    @Test("A foreign key that references its own table becomes an edge")
    func graphBuilderKeepsASelfForeignKey() {
        let columns: [String: [ColumnInfo]] = [
            "employees": [
                ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "manager_id", dataType: "integer", isNullable: true, isPrimaryKey: false)
            ]
        ]
        let keys: [String: [ForeignKeyInfo]] = [
            "employees": [
                ForeignKeyInfo(name: "fk_manager", column: "manager_id", referencedTable: "employees", referencedColumn: "id")
            ]
        ]

        let graph = ERDiagramGraphBuilder.build(allColumns: columns, allForeignKeys: keys, allIndexes: [:])
        let selfEdges = graph.edges.filter { $0.fromTable == $0.toTable }

        #expect(selfEdges.count == 1)
        #expect(selfEdges.first?.fromColumn == "manager_id")
    }

    /// The end-to-end proof: the scene draws edges before it fills the nodes, so a loop routed
    /// through the body leaves nothing behind. Sampling the strip beside the node is what tells
    /// the two apart.
    @Test("A self-referencing table paints its relationship beside itself")
    func selfLoopSurvivesTheNodeFill() {
        let node = ERTableNode(
            id: UUID(),
            tableName: "employees",
            columns: [],
            displayColumns: [
                ERColumnDisplay(
                    id: "employees.id", name: "id", dataType: "integer",
                    isPrimaryKey: true, isForeignKey: false, isNullable: false
                ),
                ERColumnDisplay(
                    id: "employees.manager_id", name: "manager_id", dataType: "integer",
                    isPrimaryKey: false, isForeignKey: true, isNullable: true
                )
            ],
            clusterId: nil
        )
        let height = ERDiagramLayout.estimateHeight(columnCount: 2)
        let nodeRect = CGRect(x: 60, y: 60, width: ERDiagramLayout.nodeWidth, height: height)
        let edge = EREdge(
            id: UUID(),
            fkName: "fk_manager",
            fromTable: "employees",
            fromColumn: "manager_id",
            toTable: "employees",
            toColumn: "id",
            cardinality: .zeroOrManyToOne
        )
        let scene = ERDiagramScene(
            nodes: [node],
            edges: [edge],
            nodeRects: [node.id: nodeRect],
            nodeIndex: ["employees": node.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: CGSize(width: nodeRect.maxX + 160, height: nodeRect.maxY + 160)
        )

        let view = ERDiagramSceneView(frame: CGRect(origin: .zero, size: scene.size))
        view.scene = scene
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: scene.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(view)
        window.layoutIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("no bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // The bitmap is at the display's backing scale, so a document point is not a pixel. Left
        // unscaled the strip lands inside the node, where the opaque fill passes the assertion
        // whether or not the loop was drawn at all.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var painted = 0
        let firstColumn = Int((nodeRect.maxX * scale).rounded()) + 1
        let lastColumn = Int(((nodeRect.maxX + ERDiagramLayout.horizontalGap) * scale).rounded())
        for x in firstColumn...lastColumn {
            for y in Int((nodeRect.minY * scale).rounded())...Int((nodeRect.maxY * scale).rounded()) {
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { continue }
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.alphaComponent > 0.05 { painted += 1 }
            }
        }

        #expect(painted > 40)
    }
}
