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
        var toggles: [UUID] = []
        var joinRequests = 0
    }

    private struct Fixture {
        let window: NSWindow
        let sceneView: ERDiagramSceneView
        let recorder: Recorder
        let nearId: UUID
        let farId: UUID
    }

    private static let canvasSize = CGSize(width: 2_400, height: 1_600)
    private static let nearCentre = CGPoint(x: 200, y: 200)
    private static let farCentre = CGPoint(x: 1_500, y: 1_000)
    private static let emptyPoint = CGPoint(x: 1_650, y: 1_150)

    private func rect(centredOn centre: CGPoint) -> CGRect {
        CGRect(x: centre.x - 100, y: centre.y - 50, width: 200, height: 100)
    }

    private func makeFixture(magnification: CGFloat, offersJoins: Bool = true) -> Fixture {
        let near = ERTableNode(id: UUID(), tableName: "near", columns: [], displayColumns: [], clusterId: nil)
        let far = ERTableNode(id: UUID(), tableName: "far", columns: [], displayColumns: [], clusterId: nil)
        let scene = ERDiagramScene(
            nodes: [near, far],
            edges: [],
            nodeRects: [near.id: rect(centredOn: Self.nearCentre), far.id: rect(centredOn: Self.farCentre)],
            nodeIndex: [near.tableName: near.id, far.tableName: far.id],
            clusterColors: [:],
            selectedNodeIds: [],
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
        sceneView.actions = ERDiagramCanvasActions(
            nodeAt: { point in scene.nodes.reversed().first { scene.nodeRects[$0.id]?.contains(point) ?? false }?.id },
            select: { recorder.selections.append($0) },
            beginDrag: { recorder.dragStarts.append($0) },
            updateDrag: { translation, _ in recorder.dragTranslations.append(translation) },
            endDrag: { recorder.endedDrags += 1 },
            scrollBy: { recorder.scrolls.append($0) },
            copyImage: { recorder.copies += 1 },
            toggleSelection: { recorder.toggles.append($0) },
            buildJoinQuery: offersJoins ? { recorder.joinRequests += 1 } : nil
        )

        scrollView.documentView = sceneView
        window.contentView = scrollView
        scrollView.magnification = magnification
        sceneView.scroll(CGPoint(x: Self.farCentre.x - 300 / magnification, y: Self.farCentre.y - 200 / magnification))
        window.layoutIfNeeded()
        return Fixture(window: window, sceneView: sceneView, recorder: recorder, nearId: near.id, farId: far.id)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
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

    @Test("Command- or Shift-click toggles a table instead of replacing the selection", arguments: [true, false])
    func modifiedClickToggles(usesCommand: Bool) throws {
        let modifier: NSEvent.ModifierFlags = usesCommand ? .command : .shift
        let fixture = makeFixture(magnification: 0.5)
        let pointer = fixture.sceneView.convert(Self.farCentre, to: nil)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window, modifiers: modifier))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window, modifiers: modifier))

        #expect(fixture.recorder.toggles == [fixture.farId])
        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("A Command-click on empty canvas keeps the selection")
    func modifiedClickOnEmptyCanvasKeepsSelection() throws {
        let fixture = makeFixture(magnification: 1.0)
        let pointer = fixture.sceneView.convert(Self.emptyPoint, to: nil)

        fixture.sceneView.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window, modifiers: .command))
        fixture.sceneView.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window, modifiers: .command))

        #expect(fixture.recorder.toggles.isEmpty)
        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("A right-click on an unselected table selects it and offers Build Join Query")
    func contextMenuOffersTheJoin() throws {
        let fixture = makeFixture(magnification: 0.5)
        var scene = fixture.sceneView.scene
        scene.selectedNodeIds = [fixture.nearId]
        fixture.sceneView.scene = scene
        let pointer = fixture.sceneView.convert(Self.farCentre, to: nil)

        let menu = try #require(fixture.sceneView.menu(
            for: try mouseEvent(.rightMouseDown, at: pointer, in: fixture.window)
        ))
        #expect(fixture.recorder.selections == [fixture.farId])
        let item = try #require(menu.items.first)
        #expect(item.title == String(localized: "Build Join Query…"))
        #expect(fixture.sceneView.validateMenuItem(item))

        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(fixture.recorder.joinRequests == 1)
    }

    @Test("A right-click inside the selection keeps it, and empty canvas offers no menu")
    func contextMenuKeepsSelection() throws {
        let fixture = makeFixture(magnification: 0.5)
        var scene = fixture.sceneView.scene
        scene.selectedNodeIds = [fixture.nearId, fixture.farId]
        fixture.sceneView.scene = scene

        let onTable = fixture.sceneView.convert(Self.farCentre, to: nil)
        let onEmpty = fixture.sceneView.convert(Self.emptyPoint, to: nil)

        #expect(fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: onTable, in: fixture.window)) != nil)
        #expect(fixture.recorder.selections.isEmpty)
        #expect(fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: onEmpty, in: fixture.window)) == nil)
    }

    @Test("An engine that cannot build joins gets no menu and a disabled command")
    func noJoinsNoCommand() throws {
        let fixture = makeFixture(magnification: 1.0, offersJoins: false)
        let pointer = fixture.sceneView.convert(Self.farCentre, to: nil)
        let item = NSMenuItem(
            title: "",
            action: #selector(ERDiagramSceneView.buildJoinQuery(_:)),
            keyEquivalent: ""
        )

        #expect(fixture.sceneView.menu(for: try mouseEvent(.rightMouseDown, at: pointer, in: fixture.window)) == nil)
        #expect(!fixture.sceneView.validateMenuItem(item))
    }

    @Test("Every selected table is reported selected, the last one picked focused")
    func multipleSelectionReachesAccessibility() {
        let fixture = makeFixture(magnification: 0.5)
        var scene = fixture.sceneView.scene
        scene.selectedNodeIds = [fixture.farId, fixture.nearId]
        fixture.sceneView.scene = scene

        let selected = fixture.sceneView.accessibilitySelectedChildren() as? [ERDiagramNodeElement] ?? []
        #expect(selected.map { $0.accessibilityLabel() } == ["far", "near"])
        let focused = fixture.sceneView.accessibilityFocusedUIElement as? ERDiagramNodeElement
        #expect(focused?.accessibilityLabel() == "near")
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

    @Test("Copy on the focused canvas copies the diagram")
    func copyCopiesTheDiagram() {
        let fixture = makeFixture(magnification: 1.0)

        fixture.sceneView.copy(nil)

        #expect(fixture.recorder.copies == 1)
    }
}
