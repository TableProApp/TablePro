import AppKit
@testable import TableProTextEngine
import Testing

/// The image the user drags covers what they can see of the selection, never the whole document.
///
/// A dragging session clips its items to the visible area of the source view, so a renderer sized to the document
/// draws pixels nobody can see. Dragging one word beside the 50,000 character line these tests use built a
/// 741,797 by 29 pixel bitmap, 86MB; beside a 500,000 character line, 7,417,969 by 29 and 860MB.
@Suite
@MainActor
struct TextViewDragImageTests {
    private let viewport = NSRect(x: 0, y: 0, width: 400, height: 200)
    private let wideLine = String(repeating: "x", count: 50_000)

    private func makeEditor(_ text: String, wrapLines: Bool = false) -> (NSScrollView, TextView) {
        let scrollView = NSScrollView(frame: viewport)
        let textView = TextView(string: text, wrapLines: wrapLines)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollView.documentView = textView
        scrollView.tile()
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines()
        return (scrollView, textView)
    }

    private func documentWithAWideLine() -> String {
        let lines = (0..<100).map { "line \($0) some text here" }.joined(separator: "\n")
        return "alpha beta gamma word\n" + wideLine + "\n" + lines
    }

    private func scroll(_ scrollView: NSScrollView, _ textView: TextView, to point: NSPoint) {
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutManager.layoutLines()
    }

    private func rect(of range: NSRange, in textView: TextView) -> CGRect {
        textView.layoutManager.rectsFor(range: range).boundingRect()
    }

    private func draw(_ textView: TextView) throws -> (DraggingTextRenderer, NSBitmapImageRep) {
        let renderer = try #require(
            DraggingTextRenderer(
                fillRects: textView.visibleSelectionFillRects(),
                fragmentRenderer: textView.layoutManager.lineFragmentRenderer
            )
        )
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: renderer.frame))
        renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
        return (renderer, bitmap)
    }

    /// Counts drawn pixels inside a rect given in the text view's coordinate space.
    private func inkedPixels(in rect: CGRect, of renderer: DraggingTextRenderer, bitmap: NSBitmapImageRep) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let local = rect.offsetBy(dx: -renderer.frame.minX, dy: -renderer.frame.minY).insetBy(dx: 1, dy: 1)
        let minX = max(Int(local.minX * scale), 0)
        let maxX = min(Int(local.maxX * scale), bitmap.pixelsWide)
        let minY = max(Int(local.minY * scale), 0)
        let maxY = min(Int(local.maxY * scale), bitmap.pixelsHigh)
        guard minX < maxX, minY < maxY else { return 0 }

        var count = 0
        for pixelY in minY..<maxY {
            for pixelX in minX..<maxX where (bitmap.colorAt(x: pixelX, y: pixelY)?.alphaComponent ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }

    // MARK: - Frame

    @Test("A word selected on a short line is not as wide as the widest line in the document")
    func wordSelectionIgnoresTheWidestLine() throws {
        let (_, textView) = makeEditor(documentWithAWideLine())
        let word = (textView.string as NSString).range(of: "word")
        try #require(textView.layoutManager.maxLineWidth > 100_000, "The fixture needs a very wide line")
        textView.selectionManager.setSelectedRange(word)

        let item = try #require(textView.makeSelectionDraggingItem())

        #expect(item.draggingFrame.width <= textView.visibleRect.width)
        #expect(item.draggingFrame.width < rect(of: word, in: textView).width + 2)
    }

    @Test("The dragging frame starts where the selection's rect starts")
    func draggingFrameMatchesTheSelectionOrigin() throws {
        let (scrollView, textView) = makeEditor(documentWithAWideLine())
        let string = textView.string as NSString
        let target = string.range(of: "text here", range: string.range(of: "line 4 some text here"))
        scroll(scrollView, textView, to: NSPoint(x: 0, y: 30))
        textView.selectionManager.setSelectedRange(target)

        let item = try #require(textView.makeSelectionDraggingItem())

        let selectionRect = rect(of: target, in: textView)
        try #require(selectionRect.minX > textView.visibleRect.minX + 10, "The selection starts inside the line")
        #expect(abs(item.draggingFrame.minX - selectionRect.minX) <= 1)
        #expect(abs(item.draggingFrame.minY - selectionRect.minY) <= 1)
    }

    @Test("A selection running off the leading edge starts at the edge the user can see")
    func horizontallyClippedSelectionStartsAtTheVisibleEdge() throws {
        let (scrollView, textView) = makeEditor(documentWithAWideLine())
        let target = (textView.string as NSString).range(of: "line 4 some text here")
        scroll(scrollView, textView, to: NSPoint(x: 40, y: 30))
        textView.selectionManager.setSelectedRange(target)

        let item = try #require(textView.makeSelectionDraggingItem())

        #expect(rect(of: target, in: textView).minX < textView.visibleRect.minX, "The selection starts off screen")
        #expect(abs(item.draggingFrame.minX - textView.visibleRect.minX) <= 1)
    }

    @Test("A selection taller than the viewport is clipped to what the user can see")
    func tallSelectionIsClippedToTheViewport() throws {
        let (scrollView, textView) = makeEditor(documentWithAWideLine())
        let string = textView.string as NSString
        let start = string.range(of: "line 4 some text here").location
        let end = NSMaxRange(string.range(of: "line 80 some text here"))
        scroll(scrollView, textView, to: NSPoint(x: 0, y: 400))
        textView.selectionManager.setSelectedRange(NSRange(location: start, length: end - start))

        let item = try #require(textView.makeSelectionDraggingItem())

        #expect(item.draggingFrame.height <= textView.visibleRect.height + 1)
        #expect(item.draggingFrame.width <= textView.visibleRect.width + 1)
        #expect(textView.visibleRect.insetBy(dx: -1, dy: -1).contains(item.draggingFrame))
    }

    @Test("A selection scrolled out of view still makes an image no larger than the viewport")
    func offScreenSelectionMakesASmallImage() throws {
        let (scrollView, textView) = makeEditor(documentWithAWideLine())
        let word = (textView.string as NSString).range(of: "word")
        textView.selectionManager.setSelectedRange(word)
        scroll(scrollView, textView, to: NSPoint(x: 0, y: 1_000))
        try #require(textView.visibleSelectionFillRects().isEmpty, "The selection has scrolled out of view")

        let item = try #require(textView.makeSelectionDraggingItem())

        #expect(item.draggingFrame.width <= textView.visibleRect.width)
        #expect(item.draggingFrame.height <= textView.visibleRect.height)
        #expect(abs(item.draggingFrame.minY - rect(of: word, in: textView).minY) <= 1)
    }

    @Test("A caret with nothing selected has nothing to drag")
    func emptySelectionMakesNoItem() {
        let (_, textView) = makeEditor(documentWithAWideLine())
        textView.selectionManager.setSelectedRange(NSRange(location: 3, length: 0))

        #expect(textView.makeSelectionDraggingItem() == nil)
    }

    @Test("A text view with nothing showing it makes no drag image")
    func textViewOutsideAWindowMakesNoItem() throws {
        let textView = TextView(string: documentWithAWideLine(), wrapLines: false)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 2_000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: viewport)
        try #require(textView.visibleRect.isInfinite, "A view with no window reports an infinite visible rect")
        textView.selectionManager.setSelectedRange((textView.string as NSString).range(of: "word"))

        #expect(textView.makeSelectionDraggingItem() == nil)
    }

    @Test("A word at the far end of a very wide line is drawn where it sits")
    func selectionAtTheEndOfAWideLineIsDrawn() throws {
        let needleLine = wideLine + " needle here"
        let (scrollView, textView) = makeEditor("first line\n" + needleLine + "\nlast line")
        let needle = (textView.string as NSString).range(of: "needle")
        let needleRect = rect(of: needle, in: textView)
        scroll(scrollView, textView, to: NSPoint(x: needleRect.minX - 100, y: 0))
        textView.selectionManager.setSelectedRange(needle)

        let (renderer, bitmap) = try draw(textView)

        #expect(abs(renderer.frame.minX - needleRect.minX) <= 1)
        #expect(renderer.frame.width < needleRect.width + 2)
        #expect(
            inkedPixels(in: needleRect, of: renderer, bitmap: bitmap) > 0,
            "The glyphs at the end of the line are missing"
        )
    }

    @Test("Every fill rect covers one line fragment, and names it")
    func everyFillRectNamesItsOwnFragment() throws {
        let (_, textView) = makeEditor(documentWithAWideLine())
        let string = textView.string as NSString
        let start = string.range(of: "line 0 some text here").location
        let end = NSMaxRange(string.range(of: "line 5 some text here"))
        textView.selectionManager.setSelectedRange(NSRange(location: start, length: end - start))

        let fillRects = textView.visibleSelectionFillRects()

        #expect(fillRects.count == 6)
        #expect(Set(fillRects.map(\.fragment.id)).count == fillRects.count, "A fragment is covered twice")
        for fillRect in fillRects {
            let fragmentSpan = fillRect.fragmentOrigin.y...(fillRect.fragmentOrigin.y + fillRect.fragment.scaledHeight)
            let overlap = min(fragmentSpan.upperBound, fillRect.rect.maxY)
                - max(fragmentSpan.lowerBound, fillRect.rect.minY)
            #expect(overlap > fillRect.fragment.scaledHeight / 2, "The rect and its fragment are on different lines")
        }
    }

    // MARK: - Frame, wrapping lines

    @Test("A wrapped paragraph taller than the viewport is clipped to it")
    func wrappedParagraphIsClippedToTheViewport() throws {
        let paragraph = (0..<1_000).map { "word\($0)" }.joined(separator: " ")
        let (_, textView) = makeEditor("header line\n" + paragraph + "\ntrailer", wrapLines: true)
        let target = (textView.string as NSString).range(of: paragraph)
        try #require(textView.layoutManager.textLineForOffset(target.location)?.height ?? 0 > viewport.height)
        textView.selectionManager.setSelectedRange(target)

        let item = try #require(textView.makeSelectionDraggingItem())

        #expect(item.draggingFrame.height <= textView.visibleRect.height + 1)
        #expect(item.draggingFrame.width <= textView.visibleRect.width + 1)
    }

    @Test("A selection inside a wrapped line lines up with the fragment it's on")
    func wrappedLineFragmentSelectionAlignsWithTheFragment() throws {
        let paragraph = (0..<40).map { "word\($0)" }.joined(separator: " ")
        let (_, textView) = makeEditor("header line\n" + paragraph + "\ntrailer", wrapLines: true)
        let target = (textView.string as NSString).range(of: "word30")
        let targetRect = try #require(textView.layoutManager.rectForOffset(target.location))
        textView.selectionManager.setSelectedRange(target)

        let (renderer, bitmap) = try draw(textView)

        let wordArea = CGRect(x: targetRect.minX, y: targetRect.minY, width: 40, height: targetRect.height)
        #expect(abs(renderer.frame.minY - targetRect.minY) <= 1, "The image is not on the fragment's own line")
        #expect(abs(renderer.frame.minX - targetRect.minX) <= 1)
        #expect(inkedPixels(in: wordArea, of: renderer, bitmap: bitmap) > 0)
    }

    // MARK: - Pixels

    @Test("Each selected piece on a line is drawn, and the text between them is not")
    func multipleSelectionsOnOneLineAreAllDrawn() throws {
        let (_, textView) = makeEditor(documentWithAWideLine())
        let string = textView.string as NSString
        let alpha = string.range(of: "alpha")
        let beta = string.range(of: "beta")
        let gamma = string.range(of: "gamma")
        textView.selectionManager.setSelectedRanges([alpha, gamma])

        let (renderer, bitmap) = try draw(textView)

        #expect(inkedPixels(in: rect(of: alpha, in: textView), of: renderer, bitmap: bitmap) > 0)
        #expect(inkedPixels(in: rect(of: gamma, in: textView), of: renderer, bitmap: bitmap) > 0)
        #expect(inkedPixels(in: rect(of: beta, in: textView), of: renderer, bitmap: bitmap) == 0)
    }

    @Test("A selection over several lines draws the text on each of them")
    func multiLineSelectionDrawsEveryLine() throws {
        let (_, textView) = makeEditor(documentWithAWideLine())
        let string = textView.string as NSString
        let first = string.range(of: "line 0 some text here")
        let third = string.range(of: "line 2 some text here")
        let selection = NSRange(location: first.location, length: NSMaxRange(third) - first.location)
        textView.selectionManager.setSelectedRange(selection)

        let (renderer, bitmap) = try draw(textView)

        for line in ["line 0 some text here", "line 1 some text here", "line 2 some text here"] {
            let lineRect = rect(of: string.range(of: line), in: textView)
            #expect(inkedPixels(in: lineRect, of: renderer, bitmap: bitmap) > 0, "\(line) is missing from the image")
        }
    }

    @Test("Text before and after the selection on the same line stays clear")
    func unselectedTextOnTheSameLineIsNotDrawn() throws {
        let (_, textView) = makeEditor(documentWithAWideLine())
        let string = textView.string as NSString
        let beta = string.range(of: "beta")
        textView.selectionManager.setSelectedRange(beta)

        let (renderer, bitmap) = try draw(textView)

        #expect(inkedPixels(in: rect(of: beta, in: textView), of: renderer, bitmap: bitmap) > 0)
        #expect(renderer.frame.width < rect(of: beta, in: textView).width + 2)
        #expect(renderer.frame.minX > rect(of: string.range(of: "alpha"), in: textView).maxX - 2)
    }

    // MARK: - Pasteboard

    @Test("A cursor with no selection writes nothing to the pasteboard")
    func caretsAreLeftOutOfTheDraggedText() throws {
        let (_, textView) = makeEditor("alpha\nbeta\ngamma\n")
        let string = textView.string as NSString
        let alpha = string.range(of: "alpha")
        let caret = NSRange(location: string.range(of: "gamma").location, length: 0)
        textView.selectionManager.setSelectedRanges([alpha, caret])

        let item = try #require(textView.makeSelectionDraggingItem())

        #expect((item.item as? NSAttributedString)?.string == "alpha")
    }
}
