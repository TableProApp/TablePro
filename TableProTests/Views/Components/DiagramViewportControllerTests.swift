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

@MainActor
struct DiagramViewportControllerTests {
    private func makeScrollView(content: CGSize, visible: CGSize) -> DiagramScrollView {
        let scrollView = DiagramScrollView(frame: CGRect(origin: .zero, size: visible))
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
    ) -> (DiagramViewportController, DiagramScrollView) {
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
        #expect(viewport.magnification == DiagramZoom.ladder[0])

        viewport.resetZoom()
        #expect(viewport.magnification == 1.0)
    }

    @Test("Zooming writes through to the scroll view")
    func writesMagnificationToScrollView() {
        let (viewport, scrollView) = makeAttached()

        viewport.zoomIn()
        #expect(scrollView.magnification == DiagramZoom.stepUp(from: 1.0))

        viewport.resetZoom()
        #expect(scrollView.magnification == 1.0)
    }

    @Test("Reattaching restores the zoom the controller was left on")
    func attachRestoresRetainedMagnification() {
        let (viewport, first) = makeAttached()

        first.magnification = 0.41
        #expect(viewport.magnification == 0.41)
        viewport.detach(from: first)

        let second = makeScrollView(content: CGSize(width: 1_000, height: 800), visible: CGSize(width: 500, height: 400))
        viewport.attach(to: second)

        #expect(second.magnification == 0.41)
        #expect(viewport.magnification == 0.41)
    }

    @Test("Reattaching restores the scroll offset the controller was left on")
    func attachRestoresScrollOffset() {
        let (viewport, first) = makeAttached()
        viewport.scrollBy(CGSize(width: 120, height: 90))
        let offset = first.contentView.bounds.origin
        #expect(offset != .zero)
        viewport.detach(from: first)

        let second = makeScrollView(content: CGSize(width: 1_000, height: 800), visible: CGSize(width: 500, height: 400))
        viewport.attach(to: second)

        #expect(second.contentView.bounds.origin == offset)
    }

    /// SwiftUI makes the scroll view with no size, and AppKit rescales an offset written then once the
    /// frame arrives, so the restore has to wait for the first tile that has a size.
    @Test("A saved offset waits for the rebuilt scroll view to have a size")
    func restoreWaitsForASize() {
        let content = CGSize(width: 3_000, height: 2_000)
        let (viewport, first) = makeAttached(content: content, visible: CGSize(width: 600, height: 400))
        first.magnification = 1.5
        viewport.scrollBy(CGSize(width: 700, height: 450))
        let offset = first.contentView.bounds.origin
        viewport.detach(from: first)

        let second = makeScrollView(content: content, visible: .zero)
        viewport.attach(to: second)
        #expect(second.contentView.bounds.origin == .zero)

        second.setFrameSize(CGSize(width: 600, height: 400))
        second.tile()

        #expect(abs(second.contentView.bounds.origin.x - offset.x) < 0.5)
        #expect(abs(second.contentView.bounds.origin.y - offset.y) < 0.5)
        #expect(second.magnification == 1.5)
    }

    @Test("A canvas torn down after its replacement attached leaves the replacement attached")
    func staleDetachLeavesTheReplacementAttached() {
        let (viewport, first) = makeAttached()
        let second = makeScrollView(content: CGSize(width: 1_000, height: 800), visible: CGSize(width: 500, height: 400))

        viewport.attach(to: second)
        viewport.detach(from: first)

        #expect(second.zoomController === viewport)
        #expect(first.zoomController == nil)
        viewport.zoomIn()
        #expect(second.magnification == DiagramZoom.stepUp(from: 1.0))
    }

    @Test("Scrolling reports the distance it actually moved")
    func scrollByReportsTheAppliedDistance() {
        let (viewport, scrollView) = makeAttached()

        #expect(viewport.scrollBy(CGSize(width: 60, height: 40)) == CGSize(width: 60, height: 40))
        #expect(viewport.scrollBy(CGSize(width: 10_000, height: 0)) == CGSize(width: 1_000 - 500 - 60, height: 0))
        #expect(viewport.scrollBy(CGSize(width: 50, height: 0)) == .zero)

        viewport.detach(from: scrollView)
        #expect(viewport.scrollBy(CGSize(width: 50, height: 50)) == .zero)
    }

    @Test("The zoom buttons report when there is nowhere left to go")
    func reportsZoomLimits() {
        let (viewport, _) = makeAttached()

        for _ in 0..<20 { viewport.zoomIn() }
        #expect(!viewport.canZoomIn)
        #expect(viewport.canZoomOut)

        for _ in 0..<40 { viewport.zoomOut() }
        #expect(!viewport.canZoomOut)
        #expect(viewport.canZoomIn)
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

    @Test(
        "Fit to window fits a diagram too large for the ladder's floor",
        arguments: [CGSize(width: 8_000, height: 6_000), CGSize(width: 25_000, height: 18_000)]
    )
    func fitFitsAVeryLargeDiagram(content: CGSize) {
        let (viewport, scrollView) = makeAttached(content: content, visible: CGSize(width: 500, height: 400))

        viewport.fitToWindow()

        #expect(scrollView.magnification < 0.25)
        #expect(scrollView.documentVisibleRect.width >= content.width)
        #expect(scrollView.documentVisibleRect.height >= content.height)
    }

    /// The zoom buttons stop at 5%, but Fit has to be able to go further or a big enough diagram
    /// opens cropped, which is the whole point of the command.
    @Test("Fit to window goes below the ladder's own floor when the diagram needs it")
    func fitGoesBelowTheLadderFloor() {
        let (viewport, scrollView) = makeAttached(
            content: CGSize(width: 25_000, height: 18_000), visible: CGSize(width: 500, height: 400)
        )

        viewport.fitToWindow()

        #expect(scrollView.magnification < DiagramZoom.ladder[0])
        #expect(scrollView.magnification >= DiagramZoom.minimum)
        #expect(!viewport.canZoomOut)
        #expect(viewport.canZoomIn)

        viewport.zoomIn()

        #expect(abs(scrollView.magnification - DiagramZoom.ladder[0]) < 0.0001)
    }

    @Test("Zoom Out at the ladder's floor leaves the zoom and the scroll offset alone")
    func zoomOutAtTheFloorChangesNothing() {
        let (viewport, scrollView) = makeAttached()
        scrollView.magnification = DiagramZoom.ladder[0]
        viewport.scrollBy(CGSize(width: 40, height: 30))
        let origin = scrollView.contentView.bounds.origin

        viewport.zoomOut()

        #expect(scrollView.magnification == DiagramZoom.ladder[0])
        #expect(scrollView.contentView.bounds.origin == origin)
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
        let scrollView = DiagramScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
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
