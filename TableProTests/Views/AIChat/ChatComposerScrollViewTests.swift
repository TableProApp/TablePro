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
}
