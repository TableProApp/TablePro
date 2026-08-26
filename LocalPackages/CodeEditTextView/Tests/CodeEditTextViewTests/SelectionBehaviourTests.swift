import AppKit
@testable import CodeEditTextView
import Testing

private final class InvalidationSpy: TextSelectionManagerDelegate {
    var visibleTextRange: NSRange?
    private(set) var setNeedsDisplayCount = 0

    func setNeedsDisplay() { setNeedsDisplayCount += 1 }
    func estimatedLineHeight() -> CGFloat { 14.0 }
}

@Suite
@MainActor
struct SelectionBehaviourTests {
    private func makeLaidOutTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.wrapLines = false
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 2_000)
        textView.updateFrameIfNeeded()
        textView.frame.size.width = 900
        textView.layoutManager.invalidateLayoutForRange(textView.documentRange)
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 900, height: 2_000))
        return textView
    }

    // MARK: - Anchor

    /// Measured from a live `NSTextView`: the anchor is sticky and survives the selection crossing it.
    /// Caret at N, Shift+Right x3 gives (N, 3); Shift+Left x6 gives (N-3, 3); Shift+Right x6 returns to (N, 3).
    @Test("An anchored selection shrinks back through its anchor instead of growing both ways")
    func anchorSurvivesCrossingItself() throws {
        let textView = makeLaidOutTextView("alpha beta gamma delta epsilon zeta eta theta")
        let manager: TextSelectionManager = textView.selectionManager
        let anchor = 20

        manager.setSelectedRange(NSRange(location: anchor, length: 0))
        let selection = try #require(manager.textSelections.first)
        selection.pivot = anchor

        for _ in 0..<3 {
            manager.moveSelections(direction: .forward, destination: .character, modifySelection: true)
        }
        #expect(textView.selectedRange() == NSRange(location: anchor, length: 3))

        for _ in 0..<6 {
            manager.moveSelections(direction: .backward, destination: .character, modifySelection: true)
        }
        #expect(textView.selectedRange() == NSRange(location: anchor - 3, length: 3))

        for _ in 0..<6 {
            manager.moveSelections(direction: .forward, destination: .character, modifySelection: true)
        }
        #expect(textView.selectedRange() == NSRange(location: anchor, length: 3))
    }

    @Test("A selection never takes a negative length after the text under it is replaced")
    func editedSelectionKeepsAUsableLength() throws {
        let textView = makeLaidOutTextView("alpha beta gamma delta epsilon zeta eta theta")
        let manager: TextSelectionManager = textView.selectionManager

        manager.setSelectedRange(NSRange(location: 20, length: 0))
        let selection = try #require(manager.textSelections.first)
        selection.pivot = 20
        manager.moveSelections(direction: .backward, destination: .character, modifySelection: true)

        textView.replaceCharacters(in: NSRange(location: 0, length: 6), with: "")
        manager.moveSelections(direction: .forward, destination: .character, modifySelection: true)

        for selection in manager.textSelections {
            #expect(selection.range.length >= 0)
            #expect(selection.range.location >= 0)
        }
    }

    @Test("Replacing text clears the anchor and the preferred column it was built from")
    func editClearsStaleSelectionState() throws {
        let textView = makeLaidOutTextView("alpha beta gamma\ndelta epsilon zeta")
        let manager: TextSelectionManager = textView.selectionManager

        manager.setSelectedRange(NSRange(location: 12, length: 0))
        let selection = try #require(manager.textSelections.first)
        selection.pivot = 12
        selection.suggestedXPos = 400

        textView.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")

        for selection in manager.textSelections {
            #expect(selection.pivot == nil)
            #expect(selection.suggestedXPos == nil)
        }
    }

    // MARK: - Word boundaries

    @Test(
        "Double-clicking a SQL operator selects the operator",
        arguments: ["=", "<", ">", "+", "|", "~", "^", "$"]
    )
    func operatorsAreSelectable(_ operatorText: String) {
        let text = "WHERE id \(operatorText) 1"
        let textView = makeLaidOutTextView(text)
        let offset = (text as NSString).range(of: operatorText).location

        let range = textView.findWordBoundary(at: offset)

        #expect(range.length > 0)
        #expect(NSRange(location: offset, length: 1).intersection(range) != nil)
    }

    @Test("A run of operator characters selects as one unit")
    func operatorRunsSelectTogether() {
        let text = "WHERE a <= b"
        let textView = makeLaidOutTextView(text)
        let offset = (text as NSString).range(of: "<=").location

        let range = textView.findWordBoundary(at: offset)

        #expect(range == NSRange(location: offset, length: 2))
    }

    @Test("Identifiers still select as whole words")
    func identifiersStillSelectAsWords() {
        let text = "SELECT some_column FROM t"
        let textView = makeLaidOutTextView(text)
        let offset = (text as NSString).range(of: "some_column").location

        #expect(textView.findWordBoundary(at: offset + 2) == NSRange(location: offset, length: 11))
    }

    // MARK: - Read-only editors

    @Test("A read-only editor moves and extends its selection from the keyboard")
    func readOnlyEditorSelectsFromTheKeyboard() throws {
        let textView = makeLaidOutTextView("alpha beta gamma delta")
        textView.isEditable = false
        textView.isSelectable = true
        let manager: TextSelectionManager = textView.selectionManager

        manager.setSelectedRange(NSRange(location: 6, length: 0))
        let selection = try #require(manager.textSelections.first)
        selection.pivot = 6
        manager.moveSelections(direction: .forward, destination: .word, modifySelection: true)

        #expect(textView.selectedRange().length > 0)
    }

    @Test("Delete does not touch the selection or the kill ring in a read-only editor")
    func readOnlyEditorIgnoresDelete() {
        let text = "alpha beta gamma delta"
        let textView = makeLaidOutTextView(text)
        textView.isEditable = false
        textView.isSelectable = true
        textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))

        textView.deleteBackward(nil)
        textView.deleteWordForward(nil)

        #expect(textView.string == text)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
    }

    // MARK: - Invalidation

    @Test("Every range setter invalidates the view for a real change")
    func everySetterInvalidates() {
        let textView = makeLaidOutTextView("alpha beta gamma delta")
        let spy = InvalidationSpy()
        let manager = TextSelectionManager(
            layoutManager: textView.layoutManager,
            textStorage: textView.textStorage,
            textView: textView,
            delegate: spy
        )

        manager.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(spy.setNeedsDisplayCount >= 1)

        let afterFirst = spy.setNeedsDisplayCount
        manager.setSelectedRange(NSRange(location: 6, length: 4))
        #expect(spy.setNeedsDisplayCount > afterFirst, "A ranged selection change must repaint")

        let afterSecond = spy.setNeedsDisplayCount
        manager.setSelectedRanges([NSRange(location: 0, length: 3)])
        #expect(spy.setNeedsDisplayCount > afterSecond)

        let afterThird = spy.setNeedsDisplayCount
        manager.addSelectedRange(NSRange(location: 10, length: 2))
        #expect(spy.setNeedsDisplayCount > afterThird)
    }

    @Test("Laying out a band that was never laid out invalidates the view that draws over it")
    func layoutInvalidatesTheLayoutView() {
        let text = (0..<400).map { "SELECT column_\($0) FROM some_table;" }.joined(separator: "\n")
        let textView = RecordingTextView(string: text)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.wrapLines = false
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 6_000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.invalidateLayoutForRange(textView.documentRange)

        // Lay out only the top of the document, then ask for a band far below it.
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 900, height: 300))
        textView.invalidatedRects.removeAll()

        let band = NSRect(x: 0, y: 2_000, width: 900, height: 300)
        textView.layoutManager.layoutLines(in: band)

        // The view draws the selection and the caret line highlight into its own backing store, and only a layout
        // pass knows the text under them just moved.
        #expect(textView.invalidatedRects.contains { $0.intersects(band) })
    }
}

/// A text view that records what it was asked to redraw.
///
/// `needsDisplay` only latches for a view inside a window, so a headless test has to observe the call itself.
private final class RecordingTextView: TextView {
    var invalidatedRects: [NSRect] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidatedRects.append(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }
}
