import AppKit
@testable import CodeEditTextView
import Testing

/// A text view keeps its text out from under whatever its scroll view reserves over the leading and trailing edges
/// (#2709).
///
/// The clip view here reserves 50pt on the leading side and 30pt on the trailing side through its content insets, the
/// way the source editor reserves its gutter and its minimap. Positions are read off the real `NSClipView`, so the
/// clamping under test is AppKit's own.
@Suite
@MainActor
struct TextViewScrollInsetsTests {
    private let leading: CGFloat = 50
    private let trailing: CGFloat = 30
    private let longLine = String(repeating: "2056705 20260908142922 ", count: 40)

    private let scrollView: NSScrollView
    private let textView: TextView

    init() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        textView = TextView(string: "", wrapLines: false)
        scrollView.documentView = textView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsets(top: 0, left: leading, bottom: 0, right: trailing)
        scrollView.tile()
    }

    private var clip: NSClipView {
        scrollView.contentView
    }

    private var origin: CGFloat {
        clip.bounds.origin.x
    }

    private var uncoveredWidth: CGFloat {
        scrollView.contentSize.width - leading - trailing
    }

    /// The furthest right the view can scroll: the document's width less the part of the clip view left uncovered.
    private var trailingEdge: CGFloat {
        textView.frame.width - (clip.bounds.width - trailing)
    }

    /// AppKit aligns the clip view's origin to the backing store's pixels, so a position is only exact to half a point.
    private func isSamePosition(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= 0.5
    }

    private func load(_ string: String) {
        textView.setText(string)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines()
        textView.scroll(NSPoint(x: -1_000_000, y: 0))
    }

    private func scrollToTrailingEdge() {
        textView.scroll(NSPoint(x: 1_000_000, y: 0))
        textView.layoutManager.layoutLines()
    }

    @Test("At rest the view sits at the leading edge, with the text starting beside the leading inset")
    func restsAtTheLeadingEdge() {
        load("SELECT 1")

        #expect(origin == -leading)
        #expect(textView.visibleRect.minX == 0)
    }

    @Test("Without wrapping, the document is at least as wide as the area the insets leave uncovered")
    func documentFillsTheUncoveredWidth() {
        load("SELECT 1")

        #expect(textView.frame.width == uncoveredWidth)
    }

    @Test("Wrapped text wraps at the width the insets leave uncovered")
    func wrapsAtTheUncoveredWidth() {
        textView.wrapLines = true
        load(longLine)

        #expect(textView.textViewportSize().width == uncoveredWidth)
        #expect(textView.frame.width == uncoveredWidth)
    }

    @Test("The visible rect leaves out what the insets cover")
    func visibleRectLeavesOutTheInsets() {
        load(longLine)
        scrollToTrailingEdge()

        #expect(isSamePosition(textView.visibleRect.minX, origin + leading))
        #expect(isSamePosition(textView.visibleRect.width, uncoveredWidth))
    }

    @Test("Removing a long pasted line brings the start of every line back into view (#2709)")
    func undoingALongPasteBringsTheLineStartsBack() throws {
        let query = "SELECT * FROM pay_order\nORDER BY orderId desc\n"
        let end = (query as NSString).length
        load(query)

        textView.selectionManager.setSelectedRange(NSRange(location: end, length: 0))
        textView.replaceCharacters(in: NSRange(location: end, length: 0), with: longLine)
        textView.layoutManager.layoutLines()
        try #require(origin > 0, "Pasting follows the caret out to the end of the long line")

        textView.undo(nil)
        textView.layoutManager.layoutLines()

        #expect(textView.string == query)
        #expect(textView.frame.width == uncoveredWidth)
        #expect(origin == -leading)
    }

    @Test("A document that narrows but still overflows keeps the view as far right as it now reaches")
    func narrowingClampsToTheNewTrailingEdge() {
        load(String(repeating: "x", count: 600) + "\n" + String(repeating: "y", count: 200))
        scrollToTrailingEdge()

        textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 600), with: "")
        textView.layoutManager.layoutLines()

        #expect(textView.frame.width > uncoveredWidth)
        #expect(isSamePosition(origin, trailingEdge))
    }

    @Test("Moving to the start of a line from far right lands it beside the leading inset, not under it")
    func revealingALineStartClearsTheLeadingInset() {
        load(longLine + "\nORDER BY orderId desc")
        scrollToTrailingEdge()

        textView.selectionManager.setSelectedRange(NSRange(location: (longLine as NSString).length + 1, length: 0))
        textView.scrollSelectionToVisible()

        #expect(origin == -leading)
    }

    @Test("Moving to the end of a long line stops short of the trailing inset")
    func revealingALineEndClearsTheTrailingInset() throws {
        load(longLine + "\nshort")
        let end = (longLine as NSString).length

        textView.selectionManager.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollSelectionToVisible()

        let caret = try #require(textView.layoutManager.rectForOffset(end))
        #expect(caret.maxX - origin <= clip.bounds.width - trailing + 0.5)
        #expect(caret.minX - origin >= leading - 0.5)
    }

    @Test("Typing at the start of a line half hidden under the leading inset scrolls the caret clear of it")
    func typingUnderTheLeadingInsetRevealsTheCaret() throws {
        load(longLine + "\nshort")
        textView.scroll(NSPoint(x: -leading + 20, y: 0))

        let lineStart = (longLine as NSString).length + 1
        textView.selectionManager.setSelectedRange(NSRange(location: lineStart, length: 0))
        textView.replaceCharacters(in: NSRange(location: lineStart, length: 0), with: "a")

        let caret = try #require(textView.layoutManager.rectForOffset(lineStart + 1))
        #expect(origin < -leading + 20, "The view did not move")
        #expect(caret.minX - origin >= leading - 0.5, "The caret is still under the leading inset")
    }

    @Test("Typing in the middle of a long line while scrolled leaves the view where it is")
    func typingInViewKeepsThePosition() throws {
        load(String(repeating: "abcdefghij", count: 100) + "\nshort")
        textView.scroll(NSPoint(x: 1_000, y: 0))
        textView.layoutManager.layoutLines()
        let offset = 150
        try #require(textView.visibleRect.contains(try #require(textView.layoutManager.rectForOffset(offset))))

        textView.selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
        textView.replaceCharacters(in: NSRange(location: offset, length: 0), with: "Z")

        #expect(origin == 1_000)
    }

    @Test("Pasting a long line follows the caret to the end of it")
    func pastingALongLineRevealsTheCaret() throws {
        load("SELECT 1\n")

        textView.selectionManager.setSelectedRange(NSRange(location: 9, length: 0))
        textView.replaceCharacters(in: NSRange(location: 9, length: 0), with: longLine)

        let caret = try #require(textView.layoutManager.rectForOffset(9 + (longLine as NSString).length))
        #expect(textView.visibleRect.contains(caret))
        #expect(origin > 0)
    }

    @Test("Scrolling a range to the top left stops at the leading inset")
    func scrollToRangeWithoutCenteringClearsTheInset() {
        load(longLine)
        scrollToTrailingEdge()

        textView.scrollToRange(NSRange(location: 0, length: 0), center: false)

        #expect(origin == -leading)
    }

    @Test("Centering a range centres it in the area the insets leave uncovered")
    func scrollToRangeCentresInTheUncoveredArea() throws {
        load(longLine)
        let target = 300

        textView.scrollToRange(NSRange(location: target, length: 0))

        let rect = try #require(textView.layoutManager.rectForOffset(target))
        let centre = leading + uncoveredWidth / 2
        #expect(abs((rect.midX - origin) - centre) < 1)
    }

    @Test("Centering a range near the end of a line stops at the document's trailing edge")
    func scrollToRangeNearTheEndIsClamped() {
        load(longLine)
        let end = (longLine as NSString).length

        textView.scrollToRange(NSRange(location: end, length: 0))

        #expect(isSamePosition(origin, trailingEdge))
    }

    @Test("Scrolling to a range that is already in view leaves the view where it is")
    func scrollToRangeInViewDoesNothing() throws {
        load(longLine)
        textView.scroll(NSPoint(x: 100, y: 0))
        let inView = 40
        try #require(textView.visibleRect.contains(try #require(textView.layoutManager.rectForOffset(inView))))

        textView.scrollToRange(NSRange(location: inView, length: 0))

        #expect(origin == 100)
    }
}
