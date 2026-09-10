//
//  SourceEditorScrollViewTests.swift
//  CodeEditSourceEditor
//

import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing

/// The editor's scroll view reserves the room its floating views take on the clip view (#2709).
///
/// Positions are read off the real `NSClipView`, so what these check is that AppKit's own reveal and clamping stop at
/// the reserved edge once it is there.
@MainActor
struct SourceEditorScrollViewTests {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private let scrollView = SourceEditorScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    private let document = Document(frame: NSRect(x: 0, y: 0, width: 2_000, height: 1_000))

    init() {
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        scrollView.tile()
    }

    private var clip: NSClipView {
        scrollView.contentView
    }

    private var origin: CGFloat {
        clip.bounds.origin.x
    }

    @Test("The floating views' widths go on top of the scroll view's own insets")
    func reservationAddsToTheScrollViewsInsets() {
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 4, bottom: 8, right: 2)
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 40)

        let insets = clip.contentInsets
        #expect(insets.top == 10)
        #expect(insets.left == 74)
        #expect(insets.bottom == 8)
        #expect(insets.right == 42)
    }

    @Test("An inset added to the scroll view later is kept alongside the reservation")
    func laterScrollViewInsetsKeepTheReservation() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)

        scrollView.contentInsets.top = 30

        #expect(clip.contentInsets.top == 30)
        #expect(clip.contentInsets.left == 70)
    }

    @Test("A view at the top stays clear of a top inset added later, such as the find panel")
    func topInsetKeepsTheFirstLineClear() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)
        document.scroll(NSPoint(x: -10_000, y: -10_000))
        #expect(clip.bounds.minY == 0)

        scrollView.contentInsets.top = 30

        #expect(clip.bounds.minY == -30)
        #expect(origin == -70)
    }

    @Test("Laying the scroll view out again keeps the reservation and the position")
    func retilingKeepsTheReservation() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 40)

        scrollView.setFrameSize(NSSize(width: 700, height: 320))
        scrollView.tile()

        #expect(clip.contentInsets.left == 70)
        #expect(clip.contentInsets.right == 40)
        #expect(origin == -70)
    }

    @Test("A view at the leading edge stays there as the gutter grows and shrinks")
    func leadingEdgeFollowsTheReservation() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)
        #expect(origin == -70)

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 78, right: 0)
        #expect(origin == -78)

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 62, right: 0)
        #expect(origin == -62)
    }

    @Test("A view that has never scrolled stays at the leading edge as a fractional gutter widens")
    func fractionalGutterKeepsTheLeadingEdge() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 51.41, right: 0)
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 69.41, right: 0)

        #expect(abs(origin - -69.41) <= 0.5, "Left at \(origin)")
    }

    @Test("A view at the trailing edge stays there when the trailing reservation grows")
    func trailingEdgeFollowsTheReservation() {
        document.scroll(NSPoint(x: 10_000, y: 0))

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 0, right: 140)

        let trailingEdge = document.frame.width - (clip.bounds.width - 140)
        #expect(abs(origin - trailingEdge) <= 0.5, "Left at \(origin), the trailing edge is \(trailingEdge)")
    }

    @Test("Room AppKit reserves for legacy scrollers stays under the reservation")
    func legacyScrollerRoomIsKept() throws {
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 4, bottom: 8, right: 2)
        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        let computed = clip.contentInsets
        try #require(computed.right > 2, "AppKit reserves the legacy scroller through the clip view's insets")

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 40)

        #expect(clip.contentInsets.left == computed.left + 70)
        #expect(clip.contentInsets.right == computed.right + 40)
        #expect(clip.contentInsets.bottom == computed.bottom)
    }

    @Test("Room AppKit reserves for a ruler stays under the reservation")
    func rulerRoomIsKept() throws {
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()
        let rulerRoom = clip.contentInsets.left
        try #require(rulerRoom > 0, "AppKit reserves the ruler through the clip view's insets")

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)

        #expect(clip.contentInsets.left == rulerRoom + 70)
    }

    @Test("A scrolled view keeps its position when the gutter's width changes")
    func scrolledViewKeepsItsPosition() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)
        document.scroll(NSPoint(x: 500, y: 0))

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 78, right: 0)

        #expect(origin == 500)
    }

    @Test("Revealing the start of the document stops beside the gutter")
    func revealStopsAtTheReservation() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 40)
        document.scroll(NSPoint(x: 1_000, y: 0))

        document.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 10))

        #expect(origin == -70)
    }

    @Test("Scrolling stops at the reserved edges on both sides")
    func scrollingIsClampedToTheReservation() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 40)

        document.scroll(NSPoint(x: -10_000, y: 0))
        #expect(origin == -70)

        document.scroll(NSPoint(x: 10_000, y: 0))
        #expect(origin == document.frame.width - (clip.bounds.width - 40))
    }

    @Test("A document that narrows pulls the view back to the reserved leading edge")
    func narrowingReturnsToTheReservedEdge() {
        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)
        document.scroll(NSPoint(x: 1_000, y: 0))

        document.setFrameSize(NSSize(width: 300, height: 1_000))

        #expect(origin == -70)
    }

    @Test("A floating view over the reserved edge still takes clicks")
    func floatingViewStillTakesClicks() {
        let gutter = Document(frame: NSRect(x: 0, y: 0, width: 70, height: 1_000))
        scrollView.addFloatingSubview(gutter, for: .horizontal)

        scrollView.floatingSubviewInsets = HorizontalEdgeInsets(left: 70, right: 0)

        #expect(scrollView.hitTest(NSPoint(x: 35, y: 150)) === gutter)
    }
}
