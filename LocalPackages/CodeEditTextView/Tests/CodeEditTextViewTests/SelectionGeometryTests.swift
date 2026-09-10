import AppKit
@testable import CodeEditTextView
import Testing

/// A delegate that reports a viewport unrelated to the rect being drawn.
///
/// Selection geometry must not consult it. AppKit calls `draw(_:)` with rects outside the visible area under
/// responsive scrolling and caches the result, so a viewport-derived answer paints a band blank and leaves it that
/// way when the user scrolls back to it.
private final class FixedViewportDelegate: TextSelectionManagerDelegate {
    var visibleTextRange: NSRange?
    private(set) var setNeedsDisplayCount = 0

    func setNeedsDisplay() { setNeedsDisplayCount += 1 }
    func estimatedLineHeight() -> CGFloat { 14.0 }
}

@Suite
@MainActor
struct SelectionGeometryTests {
    private static let lineCount = 200

    private func makeLaidOutTextView() -> TextView {
        let text = (0..<Self.lineCount)
            .map { "SELECT column_\($0) FROM some_table WHERE id = \($0);" }
            .joined(separator: "\n")
        let textView = TextView(string: text)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.wrapLines = false
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 6_000)
        textView.updateFrameIfNeeded()
        textView.frame.size.width = 900
        textView.layoutManager.invalidateLayoutForRange(textView.documentRange)
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 900, height: 6_000))
        return textView
    }

    private func selectAll(in textView: TextView, delegate: TextSelectionManagerDelegate) -> (
        TextSelectionManager, TextSelectionManager.TextSelection
    ) {
        let manager = TextSelectionManager(
            layoutManager: textView.layoutManager,
            textStorage: textView.textStorage,
            textView: textView,
            delegate: delegate
        )
        manager.setSelectedRange(textView.documentRange)
        // swiftlint:disable:next force_unwrapping
        return (manager, manager.textSelections.first!)
    }

    // MARK: - Fill rects follow the drawn rect, not the viewport

    @Test("Fill rects cover a band the viewport is nowhere near")
    func fillRectsCoverAnOffViewportBand() throws {
        let textView = makeLaidOutTextView()
        let delegate = FixedViewportDelegate()
        let (manager, selection) = selectAll(in: textView, delegate: delegate)

        // The viewport is at the very top of the document; AppKit asks us to draw a band far below it.
        delegate.visibleTextRange = try #require(textView.layoutManager.textRange(
            covering: NSRect(x: 0, y: 0, width: 900, height: 300)
        ))
        let band = NSRect(x: 0, y: 2_000, width: 900, height: 300)

        let rects = manager.getFillRects(in: band, for: selection)

        #expect(!rects.isEmpty, "The selection covers this band, so it must produce fill rects for it")
        for rect in rects {
            #expect(band.intersects(rect), "Every fill rect must land inside the band we were asked to draw")
        }
    }

    @Test("Fill rects for a band do not change when the viewport moves")
    func fillRectsAreIndependentOfTheViewport() throws {
        let textView = makeLaidOutTextView()
        let delegate = FixedViewportDelegate()
        let (manager, selection) = selectAll(in: textView, delegate: delegate)
        let band = NSRect(x: 0, y: 1_200, width: 900, height: 400)

        delegate.visibleTextRange = NSRange(location: 0, length: 10)
        let withViewportAtTop = manager.getFillRects(in: band, for: selection)

        delegate.visibleTextRange = textView.layoutManager.textRange(covering: band)
        let withViewportOnBand = manager.getFillRects(in: band, for: selection)

        delegate.visibleTextRange = nil
        let withNoViewportAtAll = manager.getFillRects(in: band, for: selection)

        #expect(withViewportAtTop == withViewportOnBand)
        #expect(withViewportAtTop == withNoViewportAtAll)
        #expect(!withViewportAtTop.isEmpty)
    }

    @Test("Fill rects stay bounded by the rect being drawn")
    func fillRectsStayInsideTheDrawnRect() throws {
        let textView = makeLaidOutTextView()
        let delegate = FixedViewportDelegate()
        let (manager, selection) = selectAll(in: textView, delegate: delegate)
        delegate.visibleTextRange = textView.documentRange

        let band = NSRect(x: 0, y: 900, width: 900, height: 200)
        let rects = manager.getFillRects(in: band, for: selection)
        let documentRects = manager.getFillRects(
            in: NSRect(x: 0, y: 0, width: 900, height: textView.layoutManager.estimatedHeight()),
            for: selection
        )

        #expect(!rects.isEmpty)
        #expect(rects.count < documentRects.count, "A 200pt band must cost less than the whole document")
        for rect in rects {
            #expect(rect.minY >= band.minY - 1 && rect.maxY <= band.maxY + 1)
        }
    }

    @Test("Fill rects never contain a null or empty rect")
    func fillRectsAreAllRealRects() throws {
        let textView = makeLaidOutTextView()
        let delegate = FixedViewportDelegate()
        let (manager, selection) = selectAll(in: textView, delegate: delegate)
        delegate.visibleTextRange = textView.documentRange

        let rects = manager.getFillRects(
            in: NSRect(x: 0, y: 0, width: 900, height: textView.layoutManager.estimatedHeight()),
            for: selection
        )

        #expect(!rects.isEmpty)
        for rect in rects {
            #expect(!rect.isNull)
            #expect(!rect.isInfinite)
            #expect(rect.height > 0)
        }
        // A null rect poisons any union taken over the result.
        #expect(!rects.boundingRect().isInfinite)
    }

    // MARK: - textRange(covering:)

    @Test("textRange(covering:) spans exactly the lines the rect touches")
    func textRangeCoveringMatchesTheLinesInTheRect() throws {
        let textView = makeLaidOutTextView()
        let layoutManager: TextLayoutManager = textView.layoutManager
        let firstLine = try #require(layoutManager.textLineForIndex(10))
        let lastLine = try #require(layoutManager.textLineForIndex(14))

        let rect = NSRect(
            x: 0,
            y: firstLine.yPos + 1,
            width: 900,
            height: (lastLine.yPos + lastLine.height) - firstLine.yPos - 2
        )
        let range = try #require(layoutManager.textRange(covering: rect))

        #expect(range.location == firstLine.range.location)
        #expect(range.max == lastLine.range.max)
    }

    @Test("textRange(covering:) matches the text view's visible range")
    func textRangeCoveringMatchesVisibleTextRange() throws {
        let textView = makeLaidOutTextView()
        let expected = textView.layoutManager.textRange(covering: textView.visibleRect)
        #expect(textView.visibleTextRange == expected)
    }

    // MARK: - Multi-line range rects

    @Test("rectsFor(range:) returns a rect for every line the range covers")
    func rectsForRangeCoversEveryLine() throws {
        let textView = makeLaidOutTextView()
        let layoutManager: TextLayoutManager = textView.layoutManager

        let firstLine = try #require(layoutManager.textLineForIndex(0))
        let thirdLine = try #require(layoutManager.textLineForIndex(2))
        let threeLines = NSRange(start: firstLine.range.location, end: thirdLine.range.max)

        let rects = layoutManager.rectsFor(range: threeLines)

        #expect(rects.count >= 3)
        let distinctRows = Set(rects.map { Int($0.minY.rounded()) })
        #expect(distinctRows.count >= 3)
    }

    @Test("A rounded path for a multi-line range spans every line")
    func roundedPathSpansEveryLine() throws {
        let textView = makeLaidOutTextView()
        let layoutManager: TextLayoutManager = textView.layoutManager

        let firstLine = try #require(layoutManager.textLineForIndex(0))
        let thirdLine = try #require(layoutManager.textLineForIndex(2))
        let threeLines = NSRange(start: firstLine.range.location, end: thirdLine.range.max)

        let path = try #require(layoutManager.roundedPathForRange(threeLines))
        #expect(path.bounds.maxY >= thirdLine.yPos, "The path must reach the last line of the range")
    }

    // MARK: - Bounding rect

    @Test("boundingRect() is the union of every rect, not just the lowest one")
    func boundingRectUnionsEveryRect() {
        let wide = CGRect(x: 10, y: 0, width: 600, height: 20)
        let narrow = CGRect(x: 10, y: 20, width: 90, height: 20)
        #expect([wide, narrow].boundingRect() == CGRect(x: 10, y: 0, width: 600, height: 40))
        #expect([CGRect]().boundingRect() == .zero)
    }
}
