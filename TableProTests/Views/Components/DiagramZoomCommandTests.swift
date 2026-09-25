//
//  DiagramZoomCommandTests.swift
//  TableProTests
//
//  View > Zoom In and Zoom Out: one item per verb, answered by a focused diagram's scroll view and
//  otherwise by the window's editor text size.
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct DiagramZoomCommandTests {
    private struct Fixture {
        let scrollView: DiagramScrollView
        let viewport: DiagramViewportController
        let document: NSView
    }

    private func makeAttached(magnification: CGFloat = 1.0) -> Fixture {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let scrollView = DiagramScrollView(frame: frame)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 2_000, height: 1_500))
        scrollView.documentView = document
        let viewport = DiagramViewportController()
        viewport.attach(to: scrollView)
        scrollView.magnification = magnification
        return Fixture(scrollView: scrollView, viewport: viewport, document: document)
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test("Zoom In and Zoom Out step the attached diagram along the ladder")
    func commandsStepTheLadder() {
        let fixture = makeAttached()

        fixture.scrollView.zoomIn(nil)
        #expect(fixture.viewport.magnification == DiagramZoom.stepUp(from: 1.0))

        fixture.scrollView.zoomOut(nil)
        fixture.scrollView.zoomOut(nil)
        #expect(fixture.viewport.magnification == DiagramZoom.stepDown(from: 1.0))
    }

    @Test("The items dim at the ends of the ladder instead of falling through to text size")
    func itemsValidateAgainstTheLadder() {
        let fixture = makeAttached(magnification: DiagramZoom.maximum)
        #expect(!fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomIn(_:)))))
        #expect(fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomOut(_:)))))

        fixture.scrollView.magnification = DiagramZoom.minimum
        #expect(fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomIn(_:)))))
        #expect(!fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomOut(_:)))))
    }

    @Test("Zoom Out dims at the ladder's floor and below it, and stays put if sent anyway", arguments: [0.05, 0.03] as [CGFloat])
    func zoomOutStopsAtTheFloor(magnification: CGFloat) {
        let fixture = makeAttached(magnification: magnification)
        #expect(!fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomOut(_:)))))
        #expect(fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomIn(_:)))))

        fixture.scrollView.zoomOut(nil)
        #expect(abs(fixture.viewport.magnification - magnification) < 0.0001)

        fixture.scrollView.zoomIn(nil)
        #expect(abs(fixture.viewport.magnification - DiagramZoom.stepUp(from: magnification)) < 0.0001)
    }

    @Test("A scroll view whose diagram detached claims no zoom")
    func detachedScrollViewDisablesZoom() {
        let fixture = makeAttached()

        fixture.viewport.detach(from: fixture.scrollView)

        #expect(fixture.scrollView.zoomController == nil)
        #expect(!fixture.scrollView.validateMenuItem(item(#selector(ZoomCommandResponding.zoomIn(_:)))))
    }

    private final class ChainTail: NSViewController, ZoomCommandResponding {
        @objc func zoomIn(_ sender: Any?) {}
        @objc func zoomOut(_ sender: Any?) {}
    }

    @Test("From a focused diagram the command reaches its scroll view, not the canvas or the fallback past it")
    func focusedDiagramClaimsTheCommand() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let scrollView = DiagramScrollView(frame: frame)
        let canvas = QueryPlanDiagramCanvasView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        scrollView.documentView = canvas
        let tail = ChainTail()
        tail.view = scrollView
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = tail
        #expect(window.makeFirstResponder(canvas))

        var responder = window.firstResponder
        while let current = responder, !current.responds(to: #selector(ZoomCommandResponding.zoomIn(_:))) {
            responder = current.nextResponder
        }

        #expect(responder === scrollView)
    }

    /// Nothing but these methods keeps the editor text size reachable once the menu names protocol
    /// selectors, and a missing one compiles.
    @Test("The window still answers Zoom In and Zoom Out when no diagram has focus")
    func windowKeepsTheTextSizeFallback() {
        #expect(MainSplitViewController.instancesRespond(to: #selector(ZoomCommandResponding.zoomIn(_:))))
        #expect(MainSplitViewController.instancesRespond(to: #selector(ZoomCommandResponding.zoomOut(_:))))
    }

    private final class FocusableDocument: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test("A click on the pane around a small diagram gives the diagram focus")
    func clickBesideTheDocumentFocusesIt() throws {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let scrollView = DiagramScrollView(frame: frame)
        let document = FocusableDocument(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = document
        window.contentView = scrollView
        window.makeFirstResponder(nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 500, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        scrollView.mouseDown(with: event)

        #expect(window.firstResponder === document)
    }

    @Test("View offers one Zoom In and one Zoom Out, left to the responder chain")
    func viewMenuCarriesOneItemPerVerb() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let view = try #require(menu.items.first { $0.title == String(localized: "View") }?.submenu)
        let zoomIns = view.items.filter { $0.action == #selector(ZoomCommandResponding.zoomIn(_:)) }
        let zoomOuts = view.items.filter { $0.action == #selector(ZoomCommandResponding.zoomOut(_:)) }
        #expect(zoomIns.count == 1)
        #expect(zoomOuts.count == 1)

        let zoomIn = try #require(zoomIns.first)
        let zoomOut = try #require(zoomOuts.first)
        #expect(zoomIn.title == String(localized: "Zoom In"))
        #expect(zoomOut.title == String(localized: "Zoom Out"))
        #expect(zoomIn.keyEquivalent == "=")
        #expect(zoomOut.keyEquivalent == "-")
        #expect(zoomIn.keyEquivalentModifierMask == .command)
        #expect(zoomOut.keyEquivalentModifierMask == .command)
        #expect(zoomIn.target == nil)
        #expect(zoomOut.target == nil)
    }
}
