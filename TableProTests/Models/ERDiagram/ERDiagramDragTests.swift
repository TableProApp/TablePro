//
//  ERDiagramDragTests.swift
//  TableProTests
//
//  AppKit owns pan and zoom, so every point the view hands the view model is already in
//  document space. These pin the hit testing, the node drag and the persisted coordinates.
//

import AppKit
import CoreGraphics
import Foundation
@testable import TablePro
import Testing

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

    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    /// A scroll view shaped like the diagram's: a flipped document sized from the model's canvas, as
    /// `MagnifiableCanvasView` sizes it.
    private func attachViewport(
        to viewModel: ERDiagramViewModel,
        visible: CGSize = CGSize(width: 500, height: 400),
        magnification: CGFloat = 1.0
    ) -> DiagramScrollView {
        let scrollView = DiagramScrollView(frame: CGRect(origin: .zero, size: visible))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum
        scrollView.documentView = FlippedDocument(frame: CGRect(origin: .zero, size: viewModel.cachedCanvasSize))
        viewModel.viewport.attach(to: scrollView)
        scrollView.magnification = magnification
        return scrollView
    }

    /// The pointer is held in the left edge band with the view already at its left edge, and in the
    /// bottom band with room to scroll down. Every tick asks for both axes and AppKit grants one, so a
    /// table that followed the scroll it asked for slid left under a still pointer.
    @Test(
        "An auto-panned table moves only as far as the view actually scrolled",
        .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    )
    func autoPanFollowsTheAppliedScroll() async throws {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 150, y: 330))
        let scrollView = attachViewport(to: viewModel)
        #expect(scrollView.contentView.bounds.origin == .zero)

        viewModel.beginDrag(at: CGPoint(x: 45, y: 330))
        viewModel.updateDrag(translation: CGSize(width: -15, height: 50), currentPoint: CGPoint(x: 30, y: 380))
        #expect(viewModel.position(for: nodeId) == CGPoint(x: 135, y: 380))

        try await Task.sleep(for: .milliseconds(150))

        let scrolled = scrollView.contentView.bounds.origin
        #expect(scrolled.x == 0)
        #expect(scrolled.y > 0)
        let position = viewModel.position(for: nodeId)
        #expect(position.x == 135)
        #expect(abs(position.y - (380 + scrolled.y)) < 0.001)
    }

    /// At 25% the edge band reaches 160 document points in, further past a table grabbed by its right
    /// edge than the 80 points of canvas beyond it, so the view had nowhere to scroll.
    @Test(
        "Auto-pan grows the canvas ahead of the view so it keeps scrolling at a low zoom",
        .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    )
    func autoPanGrowsTheCanvasAtLowZoom() async throws {
        let viewModel = makeViewModel()
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 2_300, y: 300))
        let scrollView = attachViewport(to: viewModel, magnification: 0.25)
        viewModel.viewport.scrollBy(CGSize(width: 10_000, height: 0))
        let edge = scrollView.contentView.bounds.origin.x
        #expect(edge == viewModel.cachedCanvasSize.width - 2_000)

        viewModel.beginDrag(at: CGPoint(x: 2_400, y: 300))
        viewModel.updateDrag(translation: CGSize(width: -30, height: 0), currentPoint: CGPoint(x: 2_370, y: 300))
        let held = viewModel.position(for: nodeId)

        try await Task.sleep(for: .milliseconds(150))

        let scrolled = scrollView.contentView.bounds.origin.x - edge
        #expect(scrolled > 0)
        #expect(abs(viewModel.position(for: nodeId).x - (held.x + scrolled)) < 0.001)
        #expect(scrollView.documentView?.frame.size == viewModel.cachedCanvasSize)
        viewModel.endDrag()
        ERDiagramPositionStorage.shared.clear(connectionId: viewModel.connectionId, schemaKey: "app.default")
    }

    @Test("Dropping a dragged table sizes the canvas back down to the tables")
    func endDragFitsTheCanvasToTheTables() {
        let viewModel = makeViewModel()
        defer { ERDiagramPositionStorage.shared.clear(connectionId: viewModel.connectionId, schemaKey: "app.default") }
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(translation: CGSize(width: 3_000, height: 0), currentPoint: CGPoint(x: 3_400, y: 300))
        #expect(viewModel.cachedCanvasSize.width > 3_400)
        viewModel.updateDrag(translation: .zero, currentPoint: CGPoint(x: 400, y: 300))
        viewModel.endDrag()

        #expect(viewModel.cachedCanvasSize.width > viewModel.nodeRect(for: nodeId).maxX)
        #expect(viewModel.cachedCanvasSize.width < 1_000)
    }

    /// At 25% the pane shows four times its size in document points, far more than the tables need.
    @Test("Dropping a table while zoomed out sizes the canvas to the tables, not to the pane")
    func endDragZoomedOutFitsTheTables() {
        let viewModel = makeViewModel()
        defer { ERDiagramPositionStorage.shared.clear(connectionId: viewModel.connectionId, schemaKey: "app.default") }
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))
        let scrollView = attachViewport(to: viewModel, magnification: 0.25)
        #expect(scrollView.documentVisibleRect.width > 1_000)

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(translation: CGSize(width: 100, height: 0), currentPoint: CGPoint(x: 500, y: 300))
        viewModel.endDrag()

        #expect(viewModel.cachedCanvasSize.width > viewModel.nodeRect(for: nodeId).maxX)
        #expect(viewModel.cachedCanvasSize.width < 1_000)
        #expect(viewModel.cachedCanvasSize.height < 1_000)
    }

    @Test("Dropping a table never shrinks the canvas past what is on screen")
    func endDragKeepsTheVisibleCanvas() {
        let viewModel = makeViewModel()
        defer { ERDiagramPositionStorage.shared.clear(connectionId: viewModel.connectionId, schemaKey: "app.default") }
        let nodeId = placeNode(in: viewModel, at: CGPoint(x: 400, y: 300))
        let scrollView = attachViewport(to: viewModel)

        viewModel.beginDrag(at: CGPoint(x: 400, y: 300))
        viewModel.updateDrag(translation: CGSize(width: 2_000, height: 0), currentPoint: CGPoint(x: 2_400, y: 300))
        scrollView.documentView?.setFrameSize(viewModel.cachedCanvasSize)
        viewModel.viewport.scrollBy(CGSize(width: 10_000, height: 0))
        let visibleMaxX = scrollView.documentVisibleRect.maxX
        viewModel.updateDrag(translation: CGSize(width: 1_800, height: 0), currentPoint: CGPoint(x: 2_200, y: 300))
        viewModel.endDrag()

        #expect(viewModel.nodeRect(for: nodeId).maxX < visibleMaxX - 100)
        #expect(viewModel.cachedCanvasSize.width == visibleMaxX)
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
