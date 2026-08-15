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

    private func placeNode(in viewModel: ERDiagramViewModel, at position: CGPoint) -> UUID {
        let nodeId = UUID()
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
        let position = CGPoint(x: 137.5, y: -42.25)
        let nodeId = placeNode(in: viewModel, at: position)

        #expect(viewModel.position(for: nodeId) == position)
        #expect(viewModel.nodeRect(for: nodeId).midX == position.x)
        #expect(viewModel.nodeRect(for: nodeId).midY == position.y)
        #expect(viewModel.nodeRect(for: nodeId).width == ERDiagramLayout.nodeWidth)
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
