//
//  ChatComposerScrollViewTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("ChatComposerScrollView layout")
struct ChatComposerScrollViewTests {
    private func makeComposer(width: CGFloat, height: CGFloat = 40) -> ChatComposerScrollView {
        let textView = ChatComposerNSTextView.make()
        let scrollView = ChatComposerScrollView.make(documentView: textView)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    @Test("The text view width follows the scroll view width")
    func documentWidthFollowsScrollView() throws {
        let scrollView = makeComposer(width: 420)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(abs(textView.frame.width - scrollView.contentSize.width) < 0.5)

        scrollView.setFrameSize(NSSize(width: 240, height: 40))
        scrollView.layoutSubtreeIfNeeded()
        #expect(abs(textView.frame.width - scrollView.contentSize.width) < 0.5)
    }

    @Test("The text container stays inside the text view")
    func containerTracksTextViewWidth() throws {
        let scrollView = makeComposer(width: 300)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let container = try #require(textView.textContainer)
        #expect(container.containerSize.width > 0)
        #expect(container.containerSize.width <= textView.frame.width)
    }

    @Test("Long text wraps inside the composer instead of widening it")
    func longTextWraps() throws {
        let scrollView = makeComposer(width: 260)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let container = try #require(textView.textContainer)
        let layoutManager = try #require(textView.layoutManager)

        textView.string = String(repeating: "select * from users where id = 1 ", count: 12)
        scrollView.layoutSubtreeIfNeeded()

        #expect(abs(textView.frame.width - scrollView.contentSize.width) < 0.5)
        #expect(layoutManager.usedRect(for: container).width <= container.containerSize.width + 0.5)
    }

    @Test("Height grows with content and clamps to maxLines")
    func heightClampsBetweenMinAndMaxLines() throws {
        let scrollView = makeComposer(width: 320)
        let textView = try #require(scrollView.documentView as? NSTextView)
        scrollView.minLines = 1
        scrollView.maxLines = 5

        let empty = scrollView.intrinsicContentSize.height

        textView.string = "one\ntwo\nthree"
        let threeLines = scrollView.intrinsicContentSize.height

        textView.string = String(repeating: "line\n", count: 40)
        let clamped = scrollView.intrinsicContentSize.height

        textView.string = String(repeating: "line\n", count: 200)
        let stillClamped = scrollView.intrinsicContentSize.height

        #expect(empty < threeLines)
        #expect(threeLines < clamped)
        #expect(clamped == stillClamped)
    }

    @Test("Width carries no intrinsic metric so the host drives it")
    func widthIsDrivenByTheHost() {
        let scrollView = makeComposer(width: 320)
        #expect(scrollView.intrinsicContentSize.width == NSView.noIntrinsicMetric)
    }

    /// The ring wraps the rounded surface SwiftUI paints, not the square bounds AppKit would ring
    /// on its own, so the mask has to cover the whole frame and be re-asked for when it changes.
    @Test("The focus ring mask covers the composer's own bounds")
    func focusRingMaskCoversBounds() {
        let scrollView = makeComposer(width: 320)
        #expect(scrollView.focusRingMaskBounds == scrollView.bounds)

        scrollView.setFrameSize(NSSize(width: 320, height: 96))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.focusRingMaskBounds == scrollView.bounds)
    }

    @Test("Drawing the mask leaves the whole rounded surface covered")
    func maskFillsTheRoundedSurface() throws {
        let scrollView = makeComposer(width: 320, height: 44)
        let image = NSImage(size: scrollView.bounds.size)
        image.lockFocus()
        NSColor.black.setFill()
        scrollView.drawFocusRingMask()
        image.unlockFocus()

        let bitmap = try #require(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        let centre = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        #expect(try #require(centre).alphaComponent > 0.5)
    }
}

@MainActor
@Suite("ChatComposerNSTextView accessibility")
struct ChatComposerTextViewAccessibilityTests {
    /// The placeholder is painted in `draw(_:)` and never reaches the accessibility tree, so this
    /// value is the only name the AI chat field has. It went unset from #2097 until #2995 because
    /// the one caller that set it compared against a value `makeNSView` had already stored.
    @Test("Setting the placeholder names the field for VoiceOver")
    func placeholderNamesTheField() {
        let textView = ChatComposerNSTextView.make()
        textView.placeholder = "Ask about your database…"
        #expect(textView.accessibilityPlaceholderValue() as? String == "Ask about your database…")
    }

    @Test("A later placeholder replaces the accessible name")
    func placeholderChangeUpdatesTheName() {
        let textView = ChatComposerNSTextView.make()
        textView.placeholder = "first"
        textView.placeholder = "second"
        #expect(textView.accessibilityPlaceholderValue() as? String == "second")
    }

    @Test("The context menu offers the highlight toggle in the state the preference holds")
    func contextMenuCarriesTheToggle() throws {
        let textView = ChatComposerNSTextView.make()
        var toggled = 0
        textView.onToggleHighlight = { toggled += 1 }

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.highlightEnabled = true
        let onMenu = try #require(textView.menu(for: event))
        let onItem = try #require(onMenu.items.last)
        #expect(onItem.state == .on)

        textView.highlightEnabled = false
        let offMenu = try #require(textView.menu(for: event))
        let offItem = try #require(offMenu.items.last)
        #expect(offItem.state == .off)

        let action = try #require(offItem.action)
        _ = offItem.target as AnyObject?
        NSApp.sendAction(action, to: offItem.target, from: offItem)
        #expect(toggled == 1)
    }
}
