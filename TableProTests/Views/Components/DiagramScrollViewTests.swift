//
//  DiagramScrollViewTests.swift
//  TableProTests
//
//  Drives the diagram scroll view with real scroll-wheel events. A plain magnifying NSScrollView
//  only scrolls on a Command-held wheel, measured, so these are what hold the zoom in place.
//

import AppKit
@testable import TablePro
import Testing

@Suite("Diagram scroll view")
@MainActor
struct DiagramScrollViewTests {
    private struct Fixture {
        let scrollView: DiagramScrollView
        let document: NSView
        let window: NSWindow
    }

    private func makeFixture(magnification: CGFloat = 1.0, allowsMagnification: Bool = true) -> Fixture {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let scrollView = DiagramScrollView(frame: frame)
        scrollView.allowsMagnification = allowsMagnification
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 3_000, height: 3_000))
        scrollView.documentView = document
        window.contentView = scrollView
        scrollView.magnification = magnification
        scrollView.contentView.scroll(to: CGPoint(x: 800, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
        return Fixture(scrollView: scrollView, document: document, window: window)
    }

    private func wheelEvent(lines: Int32, flags: CGEventFlags) throws -> NSEvent {
        let cgEvent = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        )
        cgEvent.flags = flags
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func expectedFactor(for event: NSEvent) -> CGFloat {
        DiagramScrollZoom.factor(for: DiagramScrollZoom.Input(event))
    }

    private final class SettlingDocument: NSView, DiagramViewportSettling {
        var settles = 0

        func viewportDidSettle() {
            settles += 1
        }
    }

    @Test("The document hears once, and only after the scroll view has a size, that its viewport settled")
    func documentSettlesOnceWithASize() {
        let scrollView = DiagramScrollView(frame: .zero)
        let document = SettlingDocument(frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        scrollView.documentView = document
        scrollView.tile()
        #expect(document.settles == 0)

        scrollView.setFrameSize(CGSize(width: 600, height: 400))
        scrollView.tile()
        scrollView.setFrameSize(CGSize(width: 700, height: 500))
        scrollView.tile()

        #expect(document.settles == 1)
    }

    @Test("A Command wheel notch zooms the diagram")
    func commandWheelZooms() throws {
        let fixture = makeFixture()
        let event = try wheelEvent(lines: 1, flags: .maskCommand)

        fixture.scrollView.scrollWheel(with: event)

        #expect(abs(fixture.scrollView.magnification - expectedFactor(for: event)) < 1e-6)
        #expect(fixture.scrollView.magnification != 1.0)
    }

    @Test("Rolling the wheel back zooms out to where it started")
    func opposingNotchesReturn() throws {
        let fixture = makeFixture(magnification: 0.5)

        fixture.scrollView.scrollWheel(with: try wheelEvent(lines: 1, flags: .maskCommand))
        fixture.scrollView.scrollWheel(with: try wheelEvent(lines: -1, flags: .maskCommand))

        #expect(abs(fixture.scrollView.magnification - 0.5) < 1e-6)
    }

    @Test(
        "A wheel without Command alone leaves the zoom where it was",
        arguments: [
            CGEventFlags().rawValue,
            CGEventFlags.maskAlternate.rawValue,
            CGEventFlags.maskControl.rawValue,
            CGEventFlags([.maskCommand, .maskShift]).rawValue
        ]
    )
    func otherChordsDoNotZoom(rawFlags: UInt64) throws {
        let fixture = makeFixture()

        fixture.scrollView.scrollWheel(with: try wheelEvent(lines: 3, flags: CGEventFlags(rawValue: rawFlags)))

        #expect(fixture.scrollView.magnification == 1.0)
    }

    @Test("The document point under the pointer stays under it", arguments: [0.5, 1.0, 2.0])
    func zoomKeepsThePointerAnchored(magnification: CGFloat) {
        let fixture = makeFixture(magnification: magnification)
        let pointer = fixture.scrollView.convert(CGPoint(x: 150, y: 110), to: nil)
        let before = fixture.document.convert(pointer, from: nil)

        fixture.scrollView.zoom(by: 1.35, around: pointer)

        let after = fixture.document.convert(pointer, from: nil)
        #expect(abs(fixture.scrollView.magnification - magnification * 1.35) < 1e-6)
        #expect(hypot(after.x - before.x, after.y - before.y) < 0.5)
    }

    @Test("Zooming stops at the scroll view's bounds")
    func zoomStopsAtTheBounds() throws {
        let fixture = makeFixture(magnification: 2.9)
        let zoomIn = try wheelEvent(lines: 3, flags: .maskCommand)
        let zoomOut = try wheelEvent(lines: -3, flags: .maskCommand)
        let inIsGrowing = expectedFactor(for: zoomIn) > 1

        for _ in 0..<40 {
            fixture.scrollView.scrollWheel(with: inIsGrowing ? zoomIn : zoomOut)
        }
        #expect(fixture.scrollView.magnification == DiagramZoom.maximum)

        for _ in 0..<200 {
            fixture.scrollView.scrollWheel(with: inIsGrowing ? zoomOut : zoomIn)
        }
        #expect(fixture.scrollView.magnification == DiagramZoom.minimum)
    }

    @Test("A scroll view that does not magnify scrolls on a Command wheel")
    func nonMagnifyingScrollViewIgnoresTheChord() throws {
        let fixture = makeFixture(allowsMagnification: false)

        fixture.scrollView.scrollWheel(with: try wheelEvent(lines: 3, flags: .maskCommand))

        #expect(fixture.scrollView.magnification == 1.0)
    }

    @Test("Responsive scrolling stays on")
    func staysCompatibleWithResponsiveScrolling() {
        #expect(DiagramScrollView.isCompatibleWithResponsiveScrolling)
    }
}
