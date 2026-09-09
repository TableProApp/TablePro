//
//  ERDiagramDragTests.swift
//  TableProTests
//
//  AppKit owns pan and zoom, so every point the view hands the view model is already in
//  document space. These pin the hit testing, the node drag and the persisted coordinates.
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

@Suite("ER diagram dragging")
@MainActor
struct ERDiagramDragTests {
    private func makeViewModel() -> ERDiagramViewModel {
        ERDiagramViewModel(connectionId: UUID(), databaseName: "app", schemaKey: "app.default")
    }

    /// Registers the node in the graph as well as in the rect cache, because hit testing resolves
    /// overlapping nodes through the graph's paint order.
    @discardableResult
    private func placeNode(in viewModel: ERDiagramViewModel, at position: CGPoint, named name: String = "t") -> UUID {
        let nodeId = UUID()
        let node = ERTableNode(id: nodeId, tableName: name, columns: [], displayColumns: [], clusterId: nil)
        var graph = viewModel.graph
        graph.nodes.append(node)
        graph.nodeIndex[name] = nodeId
        viewModel.graph = graph
        viewModel.setPositionOverride(nodeId: nodeId, position: position)
        return nodeId
    }

    @Test("A drag starting inside a node rect grabs that node")
    func beginDragHitsNodeInDocumentSpace() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))

        #expect(viewModel.isDragging)
        #expect(viewModel.draggingNodeId == nodeId)
    }

    @Test("A point inside the node rect but off its centre still grabs the node")
    func beginDragHitsNodeEdges() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))
        let rect = viewModel.nodeRect(for: nodeId)

        viewModel.beginDrag(at: CGPoint(x: rect.minX + 1, y: rect.minY + 1))

        #expect(viewModel.draggingNodeId == nodeId)
    }

    @Test("A drag starting on empty canvas pans instead of moving a node")
    func beginDragOutsideEveryNodeStartsAPan() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))
        let rect = viewModel.nodeRect(for: nodeId)

        viewModel.beginDrag(at: CGPoint(x: rect.maxX + 200, y: rect.maxY + 200))

        #expect(viewModel.isDragging)
        #expect(viewModel.draggingNodeId == nil)
    }

    @Test("A dragged node moves by the raw translation")
    func updateDragMovesNodeByRawTranslation() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(
            translation: CGSize(width: 60, height: -25),
            currentPoint: CGPoint(x: 460, y: 275)
        )

        #expect(viewModel.position(for: nodeId) == CGPoint(x: 460, y: 275))
    }

    @Test("A second update measures from the drag start, not the last position")
    func updateDragIsAbsoluteFromDragStart() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(translation: CGSize(width: 10, height: 10), currentPoint: CGPoint(x: 410, y: 310))
        viewModel.updateDrag(translation: CGSize(width: 30, height: 40), currentPoint: CGPoint(x: 430, y: 340))

        #expect(viewModel.position(for: nodeId) == CGPoint(x: 430, y: 340))
    }

    @Test("A canvas pan leaves every node where it was")
    func panDragDoesNotMoveNodes() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))
        let rect = viewModel.nodeRect(for: nodeId)

        viewModel.beginDrag(at: CGPoint(x: rect.maxX + 200, y: rect.maxY + 200))
        viewModel.updateDrag(translation: CGSize(width: 90, height: 90), currentPoint: .zero)

        #expect(viewModel.position(for: nodeId) == CGPoint(x: 400, y: 300))
    }

    @Test("Ending a drag clears the drag state")
    func endDragClearsState() {
        let viewModel = makeViewModel()
        defer { ERDiagramPositionStorage.shared.clear(connectionId: viewModel.connectionId, schemaKey: "app.default") }
        _ = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(translation: CGSize(width: 5, height: 5), currentPoint: CGPoint(x: 405, y: 305))
        viewModel.endDrag()

        #expect(!viewModel.isDragging)
        #expect(viewModel.draggingNodeId == nil)
    }

    @Test("A position override round-trips and centres the node rect on it")
    func positionOverrideRoundTrips() {
        let viewModel = makeViewModel()
        let position = CGPoint(x: 337.5, y: 142.25)
        let nodeId = placeNode(in: viewModel, at: position)

        #expect(viewModel.position(for: nodeId) == position)
        #expect(viewModel.nodeRect(for: nodeId).midX == position.x)
        #expect(viewModel.nodeRect(for: nodeId).midY == position.y)
        #expect(viewModel.nodeRect(for: nodeId).width == ERDiagramLayout.nodeWidth)
    }

    @Test("A node dragged past the canvas origin stops at the edge instead of leaving it")
    func dragStopsAtTheCanvasOrigin() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(
            translation: CGSize(width: -900, height: -900),
            currentPoint: CGPoint(x: -500, y: -600)
        )

        let rect = viewModel.nodeRect(for: nodeId)
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(viewModel.position(for: nodeId).x == ERDiagramLayout.nodeWidth / 2)
        #expect(viewModel.position(for: nodeId).y == rect.height / 2)
    }

    @Test("A drag on overlapping nodes grabs the one painted on top")
    func beginDragPrefersTheTopmostNode() {
        let viewModel = makeViewModel()
        placeNode(in: viewModel, at: CGPoint(x: 400, y: 300), named: "under")
        let topId = placeNode(in: viewModel, at: CGPoint(x: 410, y: 310), named: "over")

        viewModel.beginDrag(at: CGPoint(x: 405, y: 305))

        #expect(viewModel.draggingNodeId == topId)
        #expect(viewModel.nodeId(at: CGPoint(x: 405, y: 305)) == topId)
    }

    @Test("A position saved above or left of the origin reads back on the canvas")
    func legacyOffCanvasPositionIsClampedOnRead() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))
        viewModel.setPositionOverride(nodeId: nodeId, position: CGPoint(x: -900, y: -900))

        #expect(viewModel.position(for: nodeId).x >= ERDiagramLayout.nodeWidth / 2)
        #expect(viewModel.nodeRect(for: nodeId).minX >= 0)
        #expect(viewModel.nodeRect(for: nodeId).minY >= 0)
    }

    @Test("Reversing after an overshoot past the origin moves the node straight away")
    func dragFollowsThePointerBackAfterAnOvershoot() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(
            translation: CGSize(width: -900, height: -900),
            currentPoint: CGPoint(x: -500, y: -600)
        )
        let atTheEdge = viewModel.position(for: nodeId)

        viewModel.updateDrag(
            translation: CGSize(width: -800, height: -800),
            currentPoint: CGPoint(x: -400, y: -500)
        )

        #expect(viewModel.position(for: nodeId).x == atTheEdge.x + 100)
        #expect(viewModel.position(for: nodeId).y == atTheEdge.y + 100)
    }

    @Test("The clamp only bites at the edge and leaves an ordinary drag alone")
    func clampLeavesInteriorDragsAlone() {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 600, y: 500))

        viewModel.beginDrag(at: CGPoint(x: 600, y: 500))
        viewModel.updateDrag(translation: CGSize(width: -120, height: -80), currentPoint: CGPoint(x: 480, y: 420))

        #expect(viewModel.position(for: nodeId) == CGPoint(x: 480, y: 420))
    }

    @Test("A saved layout loads back at the same document coordinates")
    func storedPositionsSurviveARoundTrip() {
        let connectionId = UUID()
        let schemaKey = "app.public"
        let positions = ["orders": CGPoint(x: 512.5, y: -128.25), "customers": CGPoint(x: 0, y: 940)]
        defer { ERDiagramPositionStorage.shared.clear(connectionId: connectionId, schemaKey: schemaKey) }

        ERDiagramPositionStorage.shared.save(positions, connectionId: connectionId, schemaKey: schemaKey)
        let loaded = ERDiagramPositionStorage.shared.load(connectionId: connectionId, schemaKey: schemaKey)

        #expect(loaded == positions)
    }
}
