//
//  QueryPlanDiagramCanvasViewTests.swift
//  TableProTests
//
//  The plan diagram's document view at the zoom levels the app reaches: clicks, the step menu and the
//  accessibility elements all have to land on the step drawn under them.
//

import AppKit
@testable import TablePro
import Testing

@Suite("Query plan diagram canvas")
@MainActor
struct QueryPlanDiagramCanvasViewTests {
    @MainActor
    private final class Recorder {
        var selections: [UUID?] = []
    }

    private struct Fixture {
        let window: NSWindow
        let canvas: QueryPlanDiagramCanvasView
        let layout: QueryPlanDiagramLayout
        let recorder: Recorder
    }

    private func node(_ operation: String, children: [QueryPlanNode] = []) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: nil,
            schema: nil,
            alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: nil,
            estimatedRows: nil,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: nil,
            actualLoops: nil,
            properties: [:],
            children: children
        )
    }

    private func makeFixture(magnification: CGFloat) -> Fixture {
        let root = node("Hash Join", children: [
            node("Seq Scan"),
            node("Index Scan"),
            node("Sort", children: [node("Seq Scan")])
        ])
        let layout = QueryPlanDiagramLayout(root: root)

        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: frame)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum

        let canvas = QueryPlanDiagramCanvasView(frame: CGRect(origin: .zero, size: layout.canvasSize))
        let recorder = Recorder()
        canvas.update(layout: layout, selectedNodeId: nil) { recorder.selections.append($0) }

        scrollView.documentView = canvas
        window.contentView = scrollView
        scrollView.magnification = magnification
        window.layoutIfNeeded()
        return Fixture(window: window, canvas: canvas, layout: layout, recorder: recorder)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at windowPoint: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func deepestStep(in layout: QueryPlanDiagramLayout) throws -> QueryPlanDiagramLayout.Node {
        try #require(layout.nodes.max { $0.rect.maxY < $1.rect.maxY })
    }

    @Test("A click on a step's drawn centre selects that step", arguments: [0.5, 1.0, 2.0] as [CGFloat])
    func clickSelectsTheDrawnStep(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let step = try deepestStep(in: fixture.layout)
        fixture.canvas.scroll(CGPoint(x: max(0, step.rect.midX - 150), y: max(0, step.rect.midY - 100)))
        let pointer = fixture.canvas.convert(CGPoint(x: step.rect.midX, y: step.rect.midY), to: nil)

        #expect(fixture.window.contentView?.hitTest(pointer) === fixture.canvas)

        fixture.canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window))
        fixture.canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window))

        #expect(fixture.recorder.selections == [step.id])
    }

    @Test("A click on empty canvas selects nothing")
    func clickOnEmptyCanvasSelectsNothing() throws {
        let fixture = makeFixture(magnification: 0.5)
        let pointer = fixture.canvas.convert(CGPoint(x: 2, y: 2), to: nil)

        fixture.canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window))
        fixture.canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window))

        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("A press released away from its step selects nothing")
    func releaseElsewhereCancels() throws {
        let fixture = makeFixture(magnification: 0.5)
        let step = try deepestStep(in: fixture.layout)
        let pressed = fixture.canvas.convert(CGPoint(x: step.rect.midX, y: step.rect.midY), to: nil)
        let released = fixture.canvas.convert(CGPoint(x: 2, y: 2), to: nil)

        fixture.canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: pressed, in: fixture.window))
        fixture.canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: released, in: fixture.window))

        #expect(fixture.recorder.selections.isEmpty)
    }

    @Test("A step's menu offers both copy commands, and empty canvas offers none")
    func contextMenuFollowsTheStep() throws {
        let fixture = makeFixture(magnification: 0.5)
        let step = try deepestStep(in: fixture.layout)
        let onStep = fixture.canvas.convert(CGPoint(x: step.rect.midX, y: step.rect.midY), to: nil)
        let onEmpty = fixture.canvas.convert(CGPoint(x: 2, y: 2), to: nil)

        let menu = fixture.canvas.menu(for: try mouseEvent(.rightMouseDown, at: onStep, in: fixture.window))
        #expect(menu?.items.map(\.title) == [String(localized: "Copy Operation"), String(localized: "Copy Node Details")])
        #expect(fixture.canvas.menu(for: try mouseEvent(.rightMouseDown, at: onEmpty, in: fixture.window)) == nil)
    }

    @Test("VoiceOver finds one button per step, framed where the step is drawn", arguments: [0.5, 2.0] as [CGFloat])
    func accessibilityElementsTrackTheDrawing(magnification: CGFloat) {
        let fixture = makeFixture(magnification: magnification)
        let elements = fixture.canvas.accessibilityChildren() as? [QueryPlanDiagramNodeElement] ?? []

        #expect(elements.count == fixture.layout.nodes.count)
        for (element, step) in zip(elements, fixture.layout.nodes) {
            let expected = NSAccessibility.screenRect(fromView: fixture.canvas, rect: step.rect)
            let reported = element.accessibilityFrame()
            #expect(element.accessibilityRole() == .button)
            #expect(abs(reported.minX - expected.minX) < 0.5)
            #expect(abs(reported.minY - expected.minY) < 0.5)
            #expect(abs(reported.width - expected.width) < 0.5)
            #expect(abs(reported.height - expected.height) < 0.5)
        }
    }

    @Test("A pointer query over a step finds that step's element", arguments: [0.5, 2.0] as [CGFloat])
    func accessibilityHitTestFindsTheStep(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let step = try deepestStep(in: fixture.layout)
        fixture.canvas.scroll(CGPoint(x: max(0, step.rect.midX - 150), y: max(0, step.rect.midY - 100)))
        let onStep = NSAccessibility.screenPoint(
            fromView: fixture.canvas,
            point: CGPoint(x: step.rect.midX, y: step.rect.midY)
        )
        let onEmpty = NSAccessibility.screenPoint(fromView: fixture.canvas, point: CGPoint(x: 2, y: 2))

        let hit = fixture.canvas.accessibilityHitTest(onStep) as? QueryPlanDiagramNodeElement
        #expect(hit?.nodeId == step.id)
        #expect(fixture.canvas.accessibilityHitTest(onEmpty) as? QueryPlanDiagramCanvasView === fixture.canvas)
    }

    /// The query an assistive client or XCUITest actually makes starts at the window, not at the
    /// canvas, and every view on the way down answers it.
    @Test("The window's pointer query reaches a step's element", arguments: [0.5, 2.0] as [CGFloat])
    func windowHitTestReachesTheStep(magnification: CGFloat) throws {
        let fixture = makeFixture(magnification: magnification)
        let step = try deepestStep(in: fixture.layout)
        fixture.canvas.scroll(CGPoint(x: max(0, step.rect.midX - 150), y: max(0, step.rect.midY - 100)))
        let onStep = NSAccessibility.screenPoint(
            fromView: fixture.canvas,
            point: CGPoint(x: step.rect.midX, y: step.rect.midY)
        )

        let hit = fixture.window.accessibilityHitTest(onStep) as? QueryPlanDiagramNodeElement
        #expect(hit?.nodeId == step.id)
    }

    @Test("Pressing a step's element selects that step")
    func accessibilityPressSelects() throws {
        let fixture = makeFixture(magnification: 0.5)
        let elements = fixture.canvas.accessibilityChildren() as? [QueryPlanDiagramNodeElement] ?? []
        let element = try #require(elements.last)

        #expect(element.accessibilityPerformPress())
        #expect(fixture.recorder.selections == [element.nodeId])
    }

    /// Writing the same selection back never reaches `update`, so the click has to be answered by
    /// the canvas itself rather than by a binding write that changes nothing.
    @Test("Clicking the step that is already selected does not write the selection again")
    func reselectingTheSelectedStepIsHandledLocally() throws {
        let root = node("Hash Join", children: [node("Seq Scan"), node("Index Scan")])
        let layout = QueryPlanDiagramLayout(root: root)
        let selected = try #require(layout.nodes.last)
        let other = try #require(layout.nodes.first)
        let canvas = QueryPlanDiagramCanvasView(frame: CGRect(origin: .zero, size: layout.canvasSize))
        let recorder = Recorder()
        canvas.update(layout: layout, selectedNodeId: selected.id) { recorder.selections.append($0) }

        canvas.selectNode(selected.id)
        #expect(recorder.selections.isEmpty)

        canvas.selectNode(other.id)
        #expect(recorder.selections == [other.id])
    }

    @Test("A new plan replaces the step elements instead of adding to them")
    func newPlanRebuildsElements() {
        let fixture = makeFixture(magnification: 1.0)
        let replacement = QueryPlanDiagramLayout(root: node("Seq Scan"))

        fixture.canvas.update(layout: replacement, selectedNodeId: nil) { _ in }

        let elements = fixture.canvas.accessibilityChildren() as? [QueryPlanDiagramNodeElement] ?? []
        #expect(elements.map(\.nodeId) == replacement.nodes.map(\.id))
    }

    /// The plan sits under the SQL editor, so it waits for a click rather than taking focus from it.
    @Test("The plan takes focus on a click and not on arrival")
    func focusFollowsAClick() throws {
        let fixture = makeFixture(magnification: 0.5)
        #expect(fixture.canvas.acceptsFirstResponder)
        #expect(fixture.window.firstResponder !== fixture.canvas)
        let pointer = fixture.canvas.convert(CGPoint(x: 2, y: 2), to: nil)

        fixture.canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointer, in: fixture.window))
        fixture.canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: pointer, in: fixture.window))

        #expect(fixture.window.firstResponder === fixture.canvas)
    }

    @Test("Copy on the focused plan copies the diagram")
    func copyCopiesThePlan() {
        let fixture = makeFixture(magnification: 1.0)
        var copies = 0
        fixture.canvas.copyImage = { copies += 1 }

        fixture.canvas.copy(nil)

        #expect(copies == 1)
    }
}
