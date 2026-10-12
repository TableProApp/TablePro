import AppKit
import Foundation
@testable import TableProTextEngine
import Testing

/// Emphasis geometry follows the layout pass, not the drawing call.
///
/// Drawing a newly exposed strip says nothing about whether the text under an emphasis moved, and measuring every
/// emphasis in the document from `draw(_:)` cost 150ms a frame with 794 search matches on one long line. Geometry is
/// measured when a layout pass reports it has changed, and only for the emphases that pass laid out.
@Suite
@MainActor
struct EmphasisGeometryUpdateTests {
    private let visibleRect = CGRect(x: 0, y: 0, width: 600, height: 300)

    // MARK: - Nothing Changed

    @Test()
    func aPassThatLaysOutNothingNewMeasuresNoGeometry() throws {
        let textView = makeScrolledTextView(string: numberedLines(400))
        let manager = try #require(textView.emphasisManager)
        manager.addEmphasis(Emphasis(range: range(of: "line 2", in: textView), style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let path = try #require(layer.path)
        manager.geometryUpdateCount = 0

        for _ in 0..<5 {
            textView.layoutManager.layoutLines(in: visibleRect)
            redraw(textView)
        }

        #expect(manager.geometryUpdateCount == 0)
        #expect(layer.path === path)
    }

    /// Scrolling up reveals lines that have never been laid out, and laying one out moves nothing below it while its
    /// measured height matches the estimate it was holding. The emphases below it therefore keep the geometry they
    /// have. Reading the pass's wider "something was laid out" signal instead re-measured every one of them on every
    /// frame of an upward scroll, which is the work this whole path exists to avoid.
    @Test()
    func aPassThatLaysOutNewLinesAboveAnEmphasisLeavesItsGeometryAlone() throws {
        let textView = makeTallTextView(string: numberedLines(600))
        let lowerBand = CGRect(x: 0, y: 2_000, width: 1_000, height: 200)
        settle(textView, in: lowerBand)
        let manager = try #require(textView.emphasisManager)
        let line = try #require(textView.layoutManager.textLineForPosition(lowerBand.midY))
        let emphasisRange = NSRange(location: line.range.location, length: 4)
        manager.addEmphasis(Emphasis(range: emphasisRange, style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let path = try #require(layer.path)
        let laidOutBefore = try #require(laidOutMinY(of: emphasisRange, in: textView))
        manager.geometryUpdateCount = 0

        let revealingBand = lowerBand.offsetBy(dx: 0, dy: -400).union(lowerBand)
        #expect(textView.layoutManager.textLineForPosition(revealingBand.minY)?.data.lineFragments.isEmpty == true)
        textView.layoutManager.layoutLines(in: revealingBand)

        #expect(laidOutMinY(of: emphasisRange, in: textView) == laidOutBefore)
        #expect(manager.geometryUpdateCount == 0)
        #expect(layer.path === path)
    }

    // MARK: - Geometry Follows Layout

    /// The other half of the rule above: a line whose height does change when it is laid out moves everything after
    /// it, including emphases the pass never visited.
    @Test()
    func aLineThatGrowsWhenItIsLaidOutMovesTheEmphasesBelowIt() throws {
        let textView = makeScrolledTextView(string: numberedLines(400))
        let manager = try #require(textView.emphasisManager)
        let emphasisRange = range(of: "line 6", in: textView)
        manager.addEmphasis(Emphasis(range: emphasisRange, style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let drawnBefore = try #require(drawnMinY(of: layer))
        let laidOutBefore = try #require(laidOutMinY(of: emphasisRange, in: textView))

        textView.textStorage.addAttribute(
            .font,
            value: NSFont.monospacedSystemFont(ofSize: 48, weight: .regular),
            range: range(of: "line 2", in: textView)
        )
        textView.layoutManager.layoutLines(in: visibleRect)

        let laidOutAfter = try #require(laidOutMinY(of: emphasisRange, in: textView))
        #expect(laidOutAfter > laidOutBefore)
        try expectFollowed(layer, drawnBefore: drawnBefore, by: laidOutAfter - laidOutBefore)
    }

    @Test()
    func anEditThatMovesALineMovesItsEmphasis() throws {
        let textView = makeScrolledTextView(string: numberedLines(400))
        let manager = try #require(textView.emphasisManager)
        let emphasisRange = range(of: "line 5", in: textView)
        manager.addEmphasis(Emphasis(range: emphasisRange, style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let drawnBefore = try #require(drawnMinY(of: layer))
        let laidOutBefore = try #require(laidOutMinY(of: emphasisRange, in: textView))

        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n\n")
        textView.layoutManager.layoutLines(in: visibleRect)

        let laidOutAfter = try #require(laidOutMinY(of: emphasisRange, in: textView))
        #expect(laidOutAfter > laidOutBefore)
        try expectFollowed(layer, drawnBefore: drawnBefore, by: laidOutAfter - laidOutBefore)
    }

    @Test()
    func aLineHeightChangeMovesEveryEmphasis() throws {
        let textView = makeScrolledTextView(string: numberedLines(400))
        let manager = try #require(textView.emphasisManager)
        let emphasisRange = range(of: "line 3", in: textView)
        manager.addEmphasis(Emphasis(range: emphasisRange, style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let drawnBefore = try #require(drawnMinY(of: layer))
        let laidOutBefore = try #require(laidOutMinY(of: emphasisRange, in: textView))

        textView.layoutManager.lineHeightMultiplier = 3
        textView.layoutManager.layoutLines(in: visibleRect)

        let laidOutAfter = try #require(laidOutMinY(of: emphasisRange, in: textView))
        #expect(laidOutAfter > laidOutBefore)
        try expectFollowed(layer, drawnBefore: drawnBefore, by: laidOutAfter - laidOutBefore)
    }

    @Test()
    func aWrapWidthChangeMovesAWrappedEmphasis() throws {
        let line = String(repeating: "wrapped text ", count: 5)
        let scrollView = makeScrollView()
        let textView = TextView(string: Array(repeating: line, count: 20).joined(separator: "\n"), wrapLines: true)
        scrollView.documentView = textView
        scrollView.tile()
        layOut(textView)
        let manager = try #require(textView.emphasisManager)
        let emphasisRange = NSRange(location: (line.utf16.count + 1) * 2, length: 7)
        manager.addEmphasis(Emphasis(range: emphasisRange, style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let drawnBefore = try #require(drawnMinY(of: layer))
        let laidOutBefore = try #require(laidOutMinY(of: emphasisRange, in: textView))

        scrollView.setFrameSize(NSSize(width: 120, height: visibleRect.height))
        scrollView.tile()
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines()

        let laidOutAfter = try #require(laidOutMinY(of: emphasisRange, in: textView))
        #expect(laidOutAfter > laidOutBefore)
        try expectFollowed(layer, drawnBefore: drawnBefore, by: laidOutAfter - laidOutBefore)
    }

    @Test()
    func anEmphasisOnALineLaidOutLaterIsDrawnWhenThatLineIsLaidOut() throws {
        let textView = makeTallTextView(string: numberedLines(400))
        textView.layoutManager.layoutLines(in: CGRect(x: 0, y: 0, width: 1_000, height: 100))
        let manager = try #require(textView.emphasisManager)
        let emphasisRange = range(of: "line 350", in: textView)
        #expect(textView.layoutManager.rectsFor(range: emphasisRange).isEmpty)

        manager.addEmphasis(
            Emphasis(range: emphasisRange, style: .underline(color: .red), toolTip: "Line"),
            for: "e"
        )
        #expect(shapeLayer(in: textView) == nil)

        textView.layoutManager.layoutLines(in: CGRect(x: 0, y: 0, width: 1_000, height: 20_000))

        let layer = try #require(shapeLayer(in: textView))
        #expect(layer.isHidden == false)
        #expect(layer.path != nil)
        let rect = try #require(textView.layoutManager.rectsFor(range: emphasisRange).first)
        #expect(manager.toolTip(at: CGPoint(x: rect.midX, y: rect.midY)) == "Line")
    }

    /// An emphasis the layout has pushed out of the span it laid out leaves its layer behind, over text that has
    /// nothing to do with it. The layer's own drawn position is what brings it back, since its text's range is no
    /// longer anywhere the pass reports.
    @Test()
    func anEmphasisTheLayoutPushesPastTheLaidOutSpanStopsPaintingWhereItWas() throws {
        let textView = makeTallTextView(string: numberedLines(400))
        let band = CGRect(x: 0, y: 0, width: 1_000, height: 200)
        textView.layoutManager.layoutLines(in: band)
        let manager = try #require(textView.emphasisManager)
        manager.addEmphasis(Emphasis(range: range(of: "line 12", in: textView), style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        #expect(try #require(drawnMinY(of: layer)) < band.maxY)

        textView.layoutManager.lineHeightMultiplier = 6
        textView.layoutManager.layoutLines(in: band)

        #expect(layer.isHidden || (drawnMinY(of: layer) ?? 0) >= band.maxY)
    }

    /// A deletion that takes the whole end of the document away leaves an emphasis naming offsets past the new end.
    /// Its text is gone, so its layer has to stop painting: the range it holds is fixed, and nothing shifts it back
    /// inside the document, so the span an edit invalidates cannot stop at the document's length.
    @Test()
    func anEmphasisPastTheEndOfAShortenedDocumentStopsBeingDrawn() throws {
        let textView = TextView(string: "Lorem Ipsum Dolor Sit", wrapLines: false)
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        textView.layoutManager.layoutLines(in: CGRect(x: 0, y: 0, width: 1_000, height: 100))
        let manager = try #require(textView.emphasisManager)
        manager.addEmphasis(Emphasis(range: NSRange(location: 18, length: 3), style: .standard), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        #expect(layer.isHidden == false)

        textView.replaceCharacters(in: NSRange(location: 0, length: 10), with: "")
        textView.layoutManager.layoutLines(in: CGRect(x: 0, y: 0, width: 1_000, height: 100))

        #expect(layer.isHidden)
    }

    // MARK: - Animation

    @Test()
    func emphasisGeometryIsSetWithoutAnImplicitAnimation() throws {
        let textView = makeScrolledTextView(string: numberedLines(400))
        let manager = try #require(textView.emphasisManager)
        let emphasisRange = range(of: "line 5", in: textView)
        manager.addEmphasis(Emphasis(range: emphasisRange, style: .underline(color: .red)), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        let drawnBefore = try #require(drawnMinY(of: layer))

        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n\n")
        textView.layoutManager.layoutLines(in: visibleRect)

        #expect(try #require(drawnMinY(of: layer)) > drawnBefore)
        #expect(layer.animationKeys() == nil)
    }

    @Test()
    func aNewActiveStandardEmphasisStillPops() throws {
        let textView = makeScrolledTextView(string: numberedLines(400))
        let manager = try #require(textView.emphasisManager)

        manager.addEmphasis(Emphasis(range: range(of: "line 2", in: textView), style: .standard), for: "e")

        let layer = try #require(shapeLayer(in: textView))
        #expect(layer.animationKeys()?.contains("popAnimation") == true)
    }

    // MARK: - Helpers

    private func expectFollowed(
        _ layer: CAShapeLayer,
        drawnBefore: CGFloat,
        by expectedDelta: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let drawnAfter = try #require(drawnMinY(of: layer), sourceLocation: sourceLocation)
        #expect(abs((drawnAfter - drawnBefore) - expectedDelta) < 0.5, sourceLocation: sourceLocation)
    }

    private func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: visibleRect)
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    /// A text view with no scroll view, holding text none of which has been laid out yet.
    ///
    /// `visibleRect` is infinite without a scroll view, so a text view built around its text lays all of it out on
    /// the spot. The text has to arrive after the frame does for any of it to be left unlaid.
    private func makeTallTextView(string: String) -> TextView {
        let textView = TextView(string: "", wrapLines: false)
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 20_000)
        textView.setText(string)
        return textView
    }

    private func makeScrolledTextView(string: String) -> TextView {
        let scrollView = makeScrollView()
        let textView = TextView(string: string, wrapLines: false)
        scrollView.documentView = textView
        scrollView.tile()
        layOut(textView)
        return textView
    }

    /// Settles the view's frame against its scroll view before anything is measured. A frame change asks for a full
    /// re-layout, which would otherwise land in the middle of a test as an unrelated invalidation.
    private func layOut(_ textView: TextView) {
        for _ in 0..<3 {
            textView.updateFrameIfNeeded()
            textView.layoutManager.layoutLines()
        }
    }

    /// The same, for a view laying out one band of a document rather than all of it.
    ///
    /// The height the first pass reports resizes the view, which asks for a forced pass, and a forced pass lays out
    /// every line it visits whether that line moved or not.
    private func settle(_ textView: TextView, in band: CGRect) {
        for _ in 0..<3 {
            textView.updateFrameIfNeeded()
            textView.layoutManager.layoutLines(in: band)
        }
    }

    private func redraw(_ textView: TextView) {
        guard let representation = textView.bitmapImageRepForCachingDisplay(in: visibleRect) else { return }
        textView.cacheDisplay(in: visibleRect, to: representation)
    }

    private func numberedLines(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n")
    }

    private func range(of text: String, in textView: TextView) -> NSRange {
        (textView.string as NSString).range(of: text)
    }

    private func shapeLayer(in textView: TextView) -> CAShapeLayer? {
        textView.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first
    }

    private func drawnMinY(of layer: CAShapeLayer) -> CGFloat? {
        layer.path?.boundingBox.minY
    }

    private func laidOutMinY(of range: NSRange, in textView: TextView) -> CGFloat? {
        textView.layoutManager.rectsFor(range: range).map(\.minY).min()
    }
}

private extension EmphasisManager {
    @MainActor
    func toolTip(at point: CGPoint) -> String? {
        guard let textView else { return nil }
        let text = toolTips.view(textView, stringForToolTip: 0, point: point, userData: nil)
        return text.isEmpty ? nil : text
    }
}
