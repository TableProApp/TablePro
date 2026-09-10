import AppKit
@testable import CodeEditTextView
import Testing

/// The document is as wide as the widest line it still has, in both directions (#2709).
///
/// Every case edits through the text storage, the path an undo, a paste and a Find and Replace all take, and reads the
/// result back off `maxLineWidth` and the text view's frame, which is what the scroll view sizes its content from.
@Suite
@MainActor
struct TextLayoutManagerLineWidthTests {
    private let everything = NSRect(x: 0, y: 0, width: 1_000, height: 100_000)
    private let topOfDocument = NSRect(x: 0, y: 0, width: 1_000, height: 300)
    private let farDown = NSRect(x: 0, y: 3_000, width: 1_000, height: 300)
    private let longLine = String(repeating: "x", count: 400)

    private func makeTextView(_ string: String) -> TextView {
        let textView = TextView(string: string, wrapLines: false)
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        textView.layoutManager.layoutLines(in: everything)
        return textView
    }

    private func widthOf(_ textView: TextView) -> CGFloat {
        textView.layoutManager.maxLineWidth
    }

    @Test("Removing the widest line narrows the document back to the widest line left")
    func removingTheWidestLineNarrowsTheDocument() {
        let query = "SELECT * FROM pay_order\nORDER BY orderId desc\n"
        let end = (query as NSString).length
        let pasted = String(repeating: "2056705 20260908142922 ", count: 30)
        let textView = makeTextView(query)
        let narrow = widthOf(textView)
        let narrowFrame = textView.frame.width

        textView.textStorage.replaceCharacters(in: NSRange(location: end, length: 0), with: pasted)
        textView.layoutManager.layoutLines(in: everything)
        #expect(widthOf(textView) > narrow * 5)
        #expect(textView.frame.width > narrowFrame * 5)

        textView.textStorage.replaceCharacters(in: NSRange(location: end, length: (pasted as NSString).length), with: "")
        textView.layoutManager.layoutLines(in: everything)

        #expect(widthOf(textView) == narrow)
        #expect(textView.frame.width == narrowFrame)
    }

    @Test("Undoing a long paste narrows the document again")
    func undoingALongPasteNarrowsTheDocument() {
        let textView = makeTextView("SELECT 1\n")
        let narrow = widthOf(textView)

        textView.replaceCharacters(in: NSRange(location: 9, length: 0), with: longLine)
        textView.layoutManager.layoutLines(in: everything)
        #expect(widthOf(textView) > narrow)

        textView.undo(nil)
        textView.layoutManager.layoutLines(in: everything)

        #expect(widthOf(textView) == narrow)
    }

    @Test("A line shortened while it is off screen stops counting as soon as the edit lands")
    func lineShortenedOffScreenStopsCounting() {
        let textView = makeTextView(([longLine] + Array(repeating: "short", count: 300)).joined(separator: "\n"))
        let wide = widthOf(textView)

        textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 400), with: "y")
        textView.layoutManager.layoutLines(in: farDown)

        #expect(widthOf(textView) < wide / 10)
    }

    @Test("Deleting the end of the last line forgets its width, even while it is off screen")
    func deletingTheEndOfTheDocumentForgetsTheLastLine() {
        let textView = makeTextView((Array(repeating: "short", count: 300) + [longLine]).joined(separator: "\n"))
        let wide = widthOf(textView)
        let length = textView.textStorage.length

        textView.textStorage.replaceCharacters(in: NSRange(location: length - 399, length: 399), with: "")
        textView.layoutManager.layoutLines(in: topOfDocument)

        #expect(widthOf(textView) < wide / 10)
    }

    @Test("Typing in a line that is not the widest leaves the width and the frame alone")
    func typingInANarrowLineLeavesTheWidthAlone() {
        let textView = makeTextView("short\n" + longLine)
        let wide = widthOf(textView)
        let frameWidth = textView.frame.width

        textView.textStorage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "abc")
        textView.layoutManager.layoutLines(in: everything)

        #expect(widthOf(textView) == wide)
        #expect(textView.frame.width == frameWidth)
    }

    @Test("The width follows the widest line as it grows and shrinks")
    func widthFollowsTheWidestLine() {
        let textView = makeTextView("short\n" + String(repeating: "x", count: 100))
        let original = widthOf(textView)
        let end = textView.textStorage.length

        textView.textStorage.replaceCharacters(in: NSRange(location: end, length: 0), with: "xxxxxxxxxx")
        textView.layoutManager.layoutLines(in: everything)
        #expect(widthOf(textView) > original)

        textView.textStorage.replaceCharacters(in: NSRange(location: end, length: 10), with: "")
        textView.layoutManager.layoutLines(in: everything)
        #expect(widthOf(textView) == original)
    }

    @Test("Invalidating line widths forgets them, off screen included")
    func invalidatingLineWidthsForgetsOffScreenWidths() {
        let textView = makeTextView(([longLine] + Array(repeating: "short", count: 300)).joined(separator: "\n"))
        let wide = widthOf(textView)

        textView.layoutManager.invalidateLineWidths()
        textView.layoutManager.layoutLines(in: farDown)

        #expect(widthOf(textView) < wide / 10)
    }

    @Test("Setting the typing font keeps the widths of the text already there")
    func typingFontKeepsMeasuredWidths() {
        let textView = makeTextView(([longLine] + Array(repeating: "short", count: 300)).joined(separator: "\n"))
        let wide = widthOf(textView)

        textView.font = .monospacedSystemFont(ofSize: 6, weight: .regular)
        textView.letterSpacing = 0.5
        textView.layoutManager.layoutLines(in: farDown)

        #expect(widthOf(textView) == wide)
    }

    @Test("Turning wrapping on forgets the widths lines measured without it")
    func turningWrappingOnForgetsWidths() {
        let textView = makeTextView(([longLine] + Array(repeating: "short", count: 300)).joined(separator: "\n"))

        textView.layoutManager.wrapLines = true

        #expect(textView.layoutManager.lineStorage.maxWidth == 0)
    }

    @Test("Setting wrapping to the value it already has keeps the widths")
    func reassigningWrappingKeepsWidths() {
        let textView = makeTextView(([longLine] + Array(repeating: "short", count: 300)).joined(separator: "\n"))
        let wide = widthOf(textView)

        textView.layoutManager.wrapLines = false

        #expect(textView.layoutManager.lineStorage.maxWidth == wide)
    }

    @Test("Folding the widest line away narrows the document, and unfolding it widens it again")
    func foldingTheWidestLineNarrowsTheDocument() {
        let textView = makeTextView(["SELECT 1", longLine, "SELECT 2"].joined(separator: "\n"))
        let wide = widthOf(textView)
        let foldStart = ("SELECT 1" as NSString).length

        textView.layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(location: foldStart, length: 401))
        textView.layoutManager.layoutLines(in: everything)
        #expect(widthOf(textView) < wide / 5, "The folded line still counts at \(widthOf(textView))")

        textView.layoutManager.attachments.remove(atOffset: foldStart)
        textView.layoutManager.layoutLines(in: everything)
        #expect(widthOf(textView) == wide)
    }

    @Test("Removing every fold at once lets the folded lines count again once they are laid out")
    func removingEveryFoldRestoresTheWidths() {
        let textView = makeTextView(["SELECT 1", longLine, "SELECT 2"].joined(separator: "\n"))
        let wide = widthOf(textView)
        let foldStart = ("SELECT 1" as NSString).length
        textView.layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(location: foldStart, length: 401))
        textView.layoutManager.layoutLines(in: everything)

        textView.layoutManager.attachments.removeAll()
        textView.layoutManager.layoutLines(in: everything)

        #expect(widthOf(textView) == wide)
    }

    @Test("Scrolling a line out of the layout window keeps its width")
    func layingOutElsewhereKeepsMeasuredWidths() {
        let textView = makeTextView(([longLine] + Array(repeating: "short", count: 300)).joined(separator: "\n"))
        let wide = widthOf(textView)

        textView.layoutManager.layoutLines(in: farDown)

        #expect(widthOf(textView) == wide)
    }
}
