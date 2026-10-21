// Drives the ER diagram's document view with mouse events at the zoom levels the app reaches. The
// SwiftUI gestures it replaced resolved every point at the pointer's position times the zoom, so
// these pin the one thing that went wrong: the point handed on is the one drawn under the pointer.

import AppKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramPointerInputTests {
    @MainActor
    private final class Recorder {
        var selections: [UUID?] = []
        var dragStarts: [CGPoint] = []
        var dragTranslations: [CGSize] = []
        var endedDrags = 0
        var scrolls: [CGSize] = []
        var copies = 0
        var openedTables: [UUID] = []
        var selectedEdges: [UUID?] = []
        var menuTargets: [ERDiagramMenuTarget] = []
        var performed: [ERDiagramMenuCommand] = []
        var deletions = 0
        var links: [(ERDiagramColumnHit, ERDiagramColumnHit)] = []
    }

    private struct Fixture {
        let window: NSWindow
        let sceneView: ERDiagramSceneView
        let recorder: Recorder
        let farId: UUID
        let nearId: UUID
    }

    private static let canDropRelationship = true

    private static let canvasSize = CGSize(width: 2_400, height: 1_600)
    private static let nearCentre = CGPoint(x: 200, y: 200)
    private static let farCentre = CGPoint(x: 1_500, y: 1_000)
    private static let emptyPoint = CGPoint(x: 1_650, y: 1_150)

    private func rect(centredOn centre: CGPoint) -> CGRect {
        CGRect(x: centre.x - 100, y: centre.y - 50, width: 200, height: 100)
    }

    private func makeFixture(magnification: CGFloat) -> Fixture {
        let near = ERTableNode(id: UUID(), tableName: "near", columns: [], displayColumns: [], clusterId: nil)
        let far = ERTableNode(id: UUID(), tableName: "far", columns: [], displayColumns: [], clusterId: nil)
        let scene = ERDiagramScene(
            nodes: [near, far],
            edges: [],
            nodeRects: [near.id: rect(centredOn: Self.nearCentre), far.id: rect(centredOn: Self.farCentre)],
            nodeIndex: [near.tableName: near.id, far.tableName: far.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: Self.canvasSize
        )

        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: frame)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum

        let sceneView = ERDiagramSceneView(frame: CGRect(origin: .zero, size: Self.canvasSize))
        sceneView.scene = scene
        let recorder = Recorder()
        let nodeAt: (CGPoint) -> UUID? = { point in
            scene.nodes.reversed().first { scene.nodeRects[$0.id]?.contains(point) ?? false }?.id
        }
        sceneView.actions = ERDiagramCanvasActions(
            nodeAt: nodeAt,
            select: { recorder.selections.append($0) },
            beginDrag: { recorder.dragStarts.append($0) },
            updateDrag: { translation, _ in recorder.dragTranslations.append(translation) },
            endDrag: { recorder.endedDrags += 1 },
            scrollBy: { recorder.scrolls.append($0) },
            copyImage: { recorder.copies += 1 },
            columnAt: { point in Self.column(at: point, in: scene, nodeAt: nodeAt) },
            selectEdge: { recorder.selectedEdges.append($0) },
            openTable: { recorder.openedTables.append($0) },
            menuSections: { target in
                recorder.menuTargets.append(target)
                return [[ERDiagramMenuEntry("Open Table", .openTable("far"))], [ERDiagramMenuEntry("Refresh", .refresh)]]
            },
            perform: { recorder.performed.append($0) },
            canDeleteSelection: { Self.canDropRelationship },
            deleteSelection: {
                recorder.deletions += 1
                return true
            },
            canLinkColumns: { true },
            canLink: { source, target in source.nodeId != target.nodeId },
            linkColumns: { recorder.links.append(($0, $1)) }
        )

        scrollView.documentView = sceneView
        window.contentView = scrollView
        scrollView.magnification = magnification
        sceneView.scroll(CGPoint(x: Self.farCentre.x - 300 / magnification, y: Self.farCentre.y - 200 / magnification))
        window.layoutIfNeeded()
        return Fixture(window: window, sceneView: sceneView, recorder: recorder, farId: far.id, nearId: near.id)
    }

    private static func column(
        at point: CGPoint,
        in scene: ERDiagramScene,
        nodeAt: (CGPoint) -> UUID?
    ) -> ERDiagramColumnHit? {
        guard let nodeId = nodeAt(point), let rect = scene.nodeRects[nodeId] else { return nil }
        let offset = point.y - rect.minY - ERDiagramLayout.headerHeight
        guard offset >= 0 else { return nil }
        let index = Int(offset / ERDiagramLayout.columnRowHeight)
        return ERDiagramColumnHit(
            nodeId: nodeId,
            tableName: scene.nodes.first { $0.id == nodeId }?.tableName ?? "",
            columnName: "column_\(index)",
            rowRect: CGRect(
                x: rect.minX,
                y: rect.minY + ERDiagramLayout.headerHeight + CGFloat(index) * ERDiagramLayout.columnRowHeight,
                width: rect.width,
                height: ERDiagramLayout.columnRowHeight
            ),
            isDropped: false,
            canHoldKey: true
        )
    }

    private func firstRowCentre(of centre: CGPoint) -> CGPoint {
        let rect = rect(centredOn: centre)
        return CGPoint(x: rect.midX, y: rect.minY + ERDiagramLayout.headerHeight + ERDiagramLayout.columnRowHeight / 2)
    }

    private func headerPoint(of centre: CGPoint) -> CGPoint {
        let rect = rect(centredOn: centre)
        return CGPoint(x: rect.midX, y: rect.minY + 4)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        in window: NSWindow,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private func keyEvent(keyCode: UInt16, characters: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func click(_ fixture: Fixture, atDocumentPoint point: CGPoint) throws {
        let pointer = fixture.sceneView.convert(point, to: nil)
        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window))
    }

    @Test("A click on a table's drawn centre selects that table", arguments: [0.41, 0.5, 1.0, 2.0] as [CGFloat])
    func clickSelectsTheDrawnTable(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let pointer = fixture.sceneView.convert(Self.farCentre, to: nil)

        #expect(fixture.window.contentView?.hitTest(pointer) === fixture.sceneView)

        try click(fixture, atDocumentPoint: Self.farCentre)

        #expect(fixture.recorder.selections == [fixture.farId])
        #expect(fixture.recorder.dragStarts.isEmpty)
    }

    @Test("A click on empty canvas clears the selection", arguments: [0.5, 2.0] as [CGFloat])
    func clickOnEmptyCanvasClearsSelection(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)

        try click(fixture, atDocumentPoint: Self.emptyPoint)

        #expect(fixture.recorder.selections == [nil])
    }

    @Test("A dragged table moves by the document distance the pointer travelled", arguments: [0.5, 2.0] as [CGFloat])
    func nodeDragUsesDocumentDistance(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let start = fixture.sceneView.convert(Self.farCentre, to: nil)
        let end = CGPoint(x: start.x + 40, y: start.y)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: fixture.window))
        fixture.sceneView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: fixture.window))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: fixture.window))

        let dragStart = try #require(fixture.recorder.dragStarts.first)
        let translation = try #require(fixture.recorder.dragTranslations.last)
        #expect(hypot(dragStart.x - Self.farCentre.x, dragStart.y - Self.farCentre.y) < 0.01)
        #expect(abs(translation.width - 40 / magnification) < 0.01)
        #expect(abs(translation.height) < 0.01)
        #expect(fixture.recorder.endedDrags == 1)
        #expect(fixture.recorder.selections.isEmpty)
        #expect(fixture.recorder.scrolls.isEmpty)
    }

    @Test("Dragging empty canvas pans by the pointer's travel at the current zoom", arguments: [0.5, 2.0] as [CGFloat])
    func emptyDragPans(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let start = fixture.sceneView.convert(Self.emptyPoint, to: nil)
        let middle = CGPoint(x: start.x + 20, y: start.y - 15)
        let end = CGPoint(x: start.x + 40, y: start.y - 30)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: fixture.window))
        fixture.sceneView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: middle, in: fixture.window))
        fixture.sceneView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: fixture.window))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: fixture.window))

        let panned = fixture.recorder.scrolls.reduce(CGSize.zero) {
            CGSize(width: $0.width + $1.width, height: $0.height + $1.height)
        }
        #expect(abs(panned.width - -40 / magnification) < 0.01)
        #expect(abs(panned.height - -30 / magnification) < 0.01)
        #expect(fixture.recorder.dragTranslations.isEmpty)
        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("A press that wobbles under the drag threshold still selects")
    func wobbleIsAClick() throws {
        let fixture = makeFixture(magnification: 0.5)
        let start = fixture.sceneView.convert(Self.farCentre, to: nil)
        let wobble = CGPoint(x: start.x + 1, y: start.y)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: fixture.window))
        fixture.sceneView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: wobble, in: fixture.window))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: wobble, in: fixture.window))

        #expect(fixture.recorder.selections == [fixture.farId])
        #expect(fixture.recorder.dragStarts.isEmpty)
    }

    /// A tab or connection switch takes the canvas out of its window with the button still down, and
    /// the mouse-up then never reaches it.
    @Test("A drag cut short by the canvas leaving its window still ends")
    func leavingTheWindowEndsTheDrag() throws {
        let fixture = makeFixture(magnification: 1.0)
        let start = fixture.sceneView.convert(Self.farCentre, to: nil)
        let end = CGPoint(x: start.x + 40, y: start.y)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: fixture.window))
        fixture.sceneView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: fixture.window))
        fixture.window.contentView = NSView()

        #expect(fixture.recorder.endedDrags == 1)
        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("A press that never became a drag is dropped when the canvas leaves its window")
    func leavingTheWindowDropsAPress() throws {
        let fixture = makeFixture(magnification: 1.0)
        let start = fixture.sceneView.convert(Self.farCentre, to: nil)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: fixture.window))
        fixture.window.contentView = NSView()
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: start, in: fixture.window))

        #expect(fixture.recorder.endedDrags == 0)
        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("The selected table's element reports itself selected")
    func selectionReachesAccessibility() {
        let fixture = makeFixture(magnification: 0.5)
        var scene = fixture.sceneView.scene
        scene.selectedNodeId = fixture.farId
        fixture.sceneView.scene = scene

        let elements = fixture.sceneView.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        #expect(elements.first { $0.accessibilityLabel() == "far" }?.isAccessibilitySelected() == true)
        #expect(elements.first { $0.accessibilityLabel() == "near" }?.isAccessibilitySelected() == false)
    }

    @Test("The canvas takes focus when it arrives in a window where nothing holds it")
    func canvasClaimsFocusOnArrival() {
        let fixture = makeFixture(magnification: 1.0)
        #expect(fixture.sceneView.acceptsFirstResponder)
        #expect(fixture.window.firstResponder === fixture.sceneView)
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A tab switch mounts the canvas while the outgoing tab's view still holds focus and removes that
    /// view in the same update, which leaves the window holding focus. The claim runs on a later
    /// main-queue turn, which a nested run loop inside this main-actor test never reaches, so the test
    /// suspends behind it instead.
    @Test("The canvas takes focus once the view that held it on arrival leaves")
    func canvasClaimsFocusAfterTheOutgoingViewLeaves() async {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: frame)
        window.contentView = container
        let outgoing = FocusableView(frame: frame)
        container.addSubview(outgoing)
        window.makeFirstResponder(outgoing)

        let sceneView = ERDiagramSceneView(frame: frame)
        container.addSubview(sceneView)
        #expect(window.firstResponder === outgoing)
        outgoing.removeFromSuperview()

        await afterQueuedMainWork()

        #expect(window.firstResponder === sceneView)
    }

    @Test("The canvas leaves focus alone when another view still holds it")
    func canvasLeavesHeldFocusAlone() async {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: frame)
        window.contentView = container
        let sidebar = FocusableView(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
        container.addSubview(sidebar)
        window.makeFirstResponder(sidebar)

        container.addSubview(ERDiagramSceneView(frame: frame))
        await afterQueuedMainWork()

        #expect(window.firstResponder === sidebar)
    }

    private func afterQueuedMainWork() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("A click on the canvas gives it focus back")
    func clickTakesFocus() throws {
        let fixture = makeFixture(magnification: 0.5)
        fixture.window.makeFirstResponder(nil)

        try click(fixture, atDocumentPoint: Self.emptyPoint)

        #expect(fixture.window.firstResponder === fixture.sceneView)
    }

    @Test("A double-click on a table opens it")
    func doubleClickOpensTheTable() throws {
        let fixture = makeFixture(magnification: 0.5)
        let pointer = fixture.sceneView.convert(Self.farCentre, to: nil)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window))
        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window, clickCount: 2))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window, clickCount: 2))

        #expect(fixture.recorder.openedTables == [fixture.farId])
        #expect(fixture.recorder.selections == [fixture.farId, fixture.farId])
    }

    @Test("A right-click asks for the menu of what is under the pointer and selects it", arguments: [0.5, 2.0] as [CGFloat])
    func rightClickMenusFollowTheTarget(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let header = fixture.sceneView.convert(headerPoint(of: Self.farCentre), to: nil)
        let row = fixture.sceneView.convert(firstRowCentre(of: Self.farCentre), to: nil)
        let empty = fixture.sceneView.convert(Self.emptyPoint, to: nil)

        let tableMenu = fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: header, in: fixture.window))
        _ = fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: row, in: fixture.window))
        _ = fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: empty, in: fixture.window))

        #expect(tableMenu?.items.map { $0.title } == ["Open Table", "", "Refresh"])
        #expect(fixture.recorder.menuTargets.count == 3)
        #expect(fixture.recorder.menuTargets.first == .table("far"))
        #expect(fixture.recorder.menuTargets.dropFirst().first == .column(table: "far", column: "column_0"))
        guard case .canvas(let point) = fixture.recorder.menuTargets.last else {
            Issue.record("The empty canvas did not ask for the canvas menu")
            return
        }
        #expect(hypot(point.x - Self.emptyPoint.x, point.y - Self.emptyPoint.y) < 0.01)
        #expect(fixture.recorder.selections == [fixture.farId, fixture.farId, nil])
    }

    @Test("A menu item runs its command against the diagram")
    func menuItemRunsItsCommand() throws {
        let fixture = makeFixture(magnification: 1.0)
        let header = fixture.sceneView.convert(headerPoint(of: Self.farCentre), to: nil)
        let menu = try #require(fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: header, in: fixture.window)))
        let item = try #require(menu.items.first)

        _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)

        #expect(fixture.recorder.performed == [.openTable("far")])
    }

    @Test("Delete on the focused canvas drops the selected relationship")
    func deleteKeyDropsTheSelection() throws {
        let fixture = makeFixture(magnification: 1.0)

        fixture.sceneView.keyDown(with: try keyEvent(keyCode: 51, characters: "\u{7F}", in: fixture.window))
        fixture.sceneView.keyDown(with: try keyEvent(keyCode: 117, characters: "\u{F728}", in: fixture.window))

        #expect(fixture.recorder.deletions == 2)
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ERDiagramSceneView.delete(_:)), keyEquivalent: "")
        #expect(fixture.sceneView.validateMenuItem(deleteItem))
    }

    @Test("A drag from a column's handle to a column of another table proposes that key", arguments: [0.5, 2.0] as [CGFloat])
    func handleDragLinksTwoColumns(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let sourceRow = firstRowCentre(of: Self.farCentre)
        let handle = CGPoint(x: rect(centredOn: Self.farCentre).maxX, y: sourceRow.y)
        let target = firstRowCentre(of: Self.nearCentre)

        fixture.sceneView.mouseMoved(with: try mouseEvent(
            .mouseMoved, at: fixture.sceneView.convert(sourceRow, to: nil), in: fixture.window
        ))
        fixture.sceneView.mouseDown(with: try mouseEvent(
            .leftMouseDown, at: fixture.sceneView.convert(handle, to: nil), in: fixture.window
        ))
        fixture.sceneView.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, at: fixture.sceneView.convert(target, to: nil), in: fixture.window
        ))
        fixture.sceneView.mouseUp(with: try mouseEvent(
            .leftMouseUp, at: fixture.sceneView.convert(target, to: nil), in: fixture.window
        ))

        let link = try #require(fixture.recorder.links.first)
        #expect(link.0.nodeId == fixture.farId)
        #expect(link.0.columnName == "column_0")
        #expect(link.1.nodeId == fixture.nearId)
        #expect(fixture.recorder.dragStarts.isEmpty)
        #expect(fixture.recorder.scrolls.isEmpty)
    }

    @Test("A handle drag released over nothing proposes no key")
    func handleDragOverNothingLinksNothing() throws {
        let fixture = makeFixture(magnification: 1.0)
        let sourceRow = firstRowCentre(of: Self.farCentre)
        let handle = CGPoint(x: rect(centredOn: Self.farCentre).maxX, y: sourceRow.y)

        fixture.sceneView.mouseMoved(with: try mouseEvent(
            .mouseMoved, at: fixture.sceneView.convert(sourceRow, to: nil), in: fixture.window
        ))
        fixture.sceneView.mouseDown(with: try mouseEvent(
            .leftMouseDown, at: fixture.sceneView.convert(handle, to: nil), in: fixture.window
        ))
        fixture.sceneView.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, at: fixture.sceneView.convert(Self.emptyPoint, to: nil), in: fixture.window
        ))
        fixture.sceneView.mouseUp(with: try mouseEvent(
            .leftMouseUp, at: fixture.sceneView.convert(Self.emptyPoint, to: nil), in: fixture.window
        ))

        #expect(fixture.recorder.links.isEmpty)
        #expect(fixture.recorder.dragStarts.isEmpty)
    }

    @Test("Copy on the focused canvas copies the diagram")
    func copyCopiesTheDiagram() {
        let fixture = makeFixture(magnification: 1.0)

        fixture.sceneView.copy(nil)

        #expect(fixture.recorder.copies == 1)
    }
}
