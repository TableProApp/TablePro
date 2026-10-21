// A relationship is selected by clicking its curve, so the hit test has to follow the route the
// renderer draws rather than the straight line between the two tables.

import AppKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramEdgeHitTests {
    private let left = UUID()
    private let right = UUID()

    private var nodeRects: [UUID: CGRect] {
        [
            left: CGRect(x: 0, y: 0, width: 200, height: 100),
            right: CGRect(x: 400, y: 0, width: 200, height: 100)
        ]
    }

    private var nodeIndex: [String: UUID] {
        ["orders": left, "customers": right]
    }

    private func edge() -> EREdge {
        EREdge(
            id: UUID(),
            fkName: "fk_orders_customer_id",
            fromTable: "orders",
            fromColumn: "customer_id",
            toTable: "customers",
            toColumn: "id",
            cardinality: .manyToOne
        )
    }

    @Test("A point on the drawn curve hits its edge, and a point beside it does not")
    func hitFollowsTheDrawnCurve() {
        let edge = edge()

        let onCurve = ERDiagramEdgeRenderer.edgeId(
            at: CGPoint(x: 300, y: 50), tolerance: 5, edges: [edge], nodeRects: nodeRects, nodeIndex: nodeIndex
        )
        let beside = ERDiagramEdgeRenderer.edgeId(
            at: CGPoint(x: 300, y: 70), tolerance: 5, edges: [edge], nodeRects: nodeRects, nodeIndex: nodeIndex
        )

        #expect(onCurve == edge.id)
        #expect(beside == nil)
    }

    @Test("The route the hit test reads is the one the renderer strokes")
    func routeMatchesTheRenderedPorts() throws {
        let route = try #require(
            ERDiagramEdgeRenderer.routes(edges: [edge()], nodeRects: nodeRects, nodeIndex: nodeIndex).first
        )

        #expect(route.path.boundingBoxOfPath.minX == 200)
        #expect(route.path.boundingBoxOfPath.maxX == 400)
        #expect(!route.markers.isEmpty)
    }
}
