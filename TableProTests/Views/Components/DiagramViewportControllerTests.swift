//
//  DiagramViewportControllerTests.swift
//  TableProTests
//
//  Tests the viewport controller against a real NSScrollView, so the AppKit behaviour the
//  diagrams now depend on (magnification bounds, KVO, fit) is pinned rather than assumed.
//

import AppKit
@testable import TablePro
import Testing

@Suite("Diagram Viewport Controller")
@MainActor
struct DiagramViewportControllerTests {
    private func makeScrollView(content: CGSize, visible: CGSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: visible))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum

        let documentView = NSView(frame: CGRect(origin: .zero, size: content))
        scrollView.documentView = documentView
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func makeAttached(
        content: CGSize = CGSize(width: 1_000, height: 800),
        visible: CGSize = CGSize(width: 500, height: 400)
    ) -> (DiagramViewportController, NSScrollView) {
        let scrollView = makeScrollView(content: content, visible: visible)
        let viewport = DiagramViewportController()
        viewport.attach(to: scrollView)
        return (viewport, scrollView)
    }

    @Test("A detached controller still clamps its own zoom")
    func clampsWhileDetached() {
        let viewport = DiagramViewportController()
        #expect(viewport.magnification == 1.0)

        for _ in 0..<20 { viewport.zoomIn() }
        #expect(viewport.magnification == DiagramZoom.maximum)

        for _ in 0..<40 { viewport.zoomOut() }
        #expect(viewport.magnification == DiagramZoom.minimum)

        viewport.resetZoom()
        #expect(viewport.magnification == 1.0)
    }

    @Test("Zooming writes through to the scroll view")
    func writesMagnificationToScrollView() {
        let (viewport, scrollView) = makeAttached()

        viewport.zoomIn()
        #expect(scrollView.magnification == 1.0 + DiagramZoom.step)

        viewport.resetZoom()
        #expect(scrollView.magnification == 1.0)
    }

    @Test("A magnification set on the scroll view is observed back")
    func observesMagnificationChanges() {
        let (viewport, scrollView) = makeAttached()

        scrollView.magnification = 2.0
        #expect(viewport.magnification == 2.0)

        scrollView.magnification = 0.5
        #expect(viewport.magnification == 0.5)
    }

    @Test("AppKit enforces the magnification bounds it was given")
    func scrollViewEnforcesBounds() {
        let (_, scrollView) = makeAttached()

        scrollView.magnification = 99
        #expect(scrollView.magnification == DiagramZoom.maximum)

        scrollView.magnification = 0.001
        #expect(scrollView.magnification == DiagramZoom.minimum)
    }

    @Test("Fit to window zooms out to show the whole diagram")
    func fitZoomsOutToFitContent() {
        let (viewport, scrollView) = makeAttached(
            content: CGSize(width: 1_000, height: 800), visible: CGSize(width: 500, height: 400)
        )

        viewport.fitToWindow()

        #expect(scrollView.magnification < 1.0)
        #expect(scrollView.magnification >= DiagramZoom.minimum)
    }

    @Test("Fit to window never zooms past one hundred percent")
    func fitNeverZoomsIn() {
        let (viewport, scrollView) = makeAttached(
            content: CGSize(width: 100, height: 80), visible: CGSize(width: 800, height: 600)
        )

        viewport.fitToWindow()

        #expect(scrollView.magnification == 1.0)
    }

    @Test("Fit to window is a no-op without a document")
    func fitIgnoresMissingDocument() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.allowsMagnification = true
        let viewport = DiagramViewportController()
        viewport.attach(to: scrollView)

        viewport.fitToWindow()

        #expect(viewport.magnification == 1.0)
    }

    @Test("Scrolling by a delta moves the visible rect")
    func scrollByMovesViewport() {
        let (viewport, scrollView) = makeAttached()
        let before = scrollView.contentView.bounds.origin

        viewport.scrollBy(CGSize(width: 60, height: 40))

        #expect(scrollView.contentView.bounds.origin != before)
    }
}
