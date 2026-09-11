import AppKit
@testable import CodeEditTextView
import Foundation
import Testing

@Suite()
struct EmphasisManagerTests {
    @Test()
    @MainActor
    func testFlashEmphasisLayersNotLeaked() {
        // Ensure layers are not leaked when switching from flash emphasis to any other emphasis type.
        let textView = makeLaidOutTextView()
        textView.emphasisManager?.addEmphasis(
            Emphasis(range: NSRange(location: 0, length: 5), style: .standard, flash: true),
            for: "e"
        )

        // Text layer and emphasis layer
        #expect(textView.layer?.sublayers?.count == 2)
        #expect(textView.emphasisManager?.getEmphases(for: "e").count == 1)

        textView.emphasisManager?.addEmphases(
            [Emphasis(range: NSRange(location: 0, length: 5), style: .underline(color: .red), flash: true)],
            for: "e"
        )

        #expect(textView.layer?.sublayers?.count == 4)
        #expect(textView.emphasisManager?.getEmphases(for: "e").count == 2)

        textView.emphasisManager?.removeAllEmphases()

        // No emphasis layers remain
        #expect(textView.layer?.sublayers?.count == nil)
        #expect(textView.emphasisManager?.getEmphases(for: "e").count == 0)
    }

    @Test()
    @MainActor
    func testUnderlineEmphasisWithoutRectsDrawsNothing() {
        // A range that produces no rects used to yield an element-less path, whose bounds raise while drawing.
        let textView = makeLaidOutTextView()

        textView.emphasisManager?.addEmphasis(
            Emphasis(range: NSRange(location: 3, length: 0), style: .underline(color: .red)),
            for: "e"
        )
        textView.emphasisManager?.updateLayerBackgrounds()

        #expect(textView.layer?.sublayers?.count == nil)
    }

    @Test()
    @MainActor
    func testUnderlineEmphasisWithRectsKeepsDrawing() {
        let textView = makeLaidOutTextView()

        textView.emphasisManager?.addEmphasis(
            Emphasis(range: NSRange(location: 0, length: 5), style: .underline(color: .red)),
            for: "e"
        )
        textView.emphasisManager?.updateLayerBackgrounds()

        // Emphasis layer and text layer
        #expect(textView.layer?.sublayers?.count == 2)
    }

    @Test()
    @MainActor
    func testEmphasisOutlivingTheTextItMarksSurvivesRedraw() {
        // Redrawing an emphasis whose text has been deleted used to raise from `NSBezierPath.bounds`.
        let textView = makeLaidOutTextView()

        textView.emphasisManager?.addEmphasis(
            Emphasis(range: NSRange(location: 6, length: 5), style: .underline(color: .red)),
            for: "e"
        )
        textView.textStorage.replaceCharacters(in: NSRange(location: 5, length: 6), with: "")
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        textView.emphasisManager?.updateLayerBackgrounds()

        #expect(textView.emphasisManager?.getEmphases(for: "e").count == 1)
        #expect(textView.layer?.sublayers?.count == 2)
    }

    /// The layer keeps the last path it was given, so an emphasis whose text has been deleted would
    /// otherwise go on painting over whatever now occupies that place. A search highlight was the
    /// worst case: a range past the end resolves to the caret rect, so it reappeared at the end of
    /// the document instead of disappearing.
    @Test()
    @MainActor
    func anEmphasisWhoseTextIsGoneStopsBeingDrawn() throws {
        let textView = makeLaidOutTextView()

        textView.emphasisManager?.addEmphasis(
            Emphasis(range: NSRange(location: 6, length: 5), style: .standard),
            for: "e"
        )
        let layer = try #require(textView.layer?.sublayers?.first)
        #expect(layer.isHidden == false)

        textView.textStorage.replaceCharacters(in: NSRange(location: 5, length: 6), with: "")
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        textView.emphasisManager?.updateLayerBackgrounds()

        #expect(textView.layer?.sublayers?.allSatisfy(\.isHidden) == true)
    }

    @Test()
    @MainActor
    func anEmphasisWhoseTextIsStillThereKeepsBeingDrawn() {
        let textView = makeLaidOutTextView()

        textView.emphasisManager?.addEmphasis(
            Emphasis(range: NSRange(location: 0, length: 5), style: .standard),
            for: "e"
        )
        textView.emphasisManager?.updateLayerBackgrounds()

        #expect(textView.layer?.sublayers?.contains(where: \.isHidden) == false)
    }

    @Test()
    @MainActor
    func anEmphasisToolTipCoversItsText() throws {
        let textView = makeLaidOutTextView()
        let manager = try #require(textView.emphasisManager)

        manager.addEmphasis(
            Emphasis(range: NSRange(location: 6, length: 5), style: .underline(color: .red), toolTip: "Ipsum"),
            for: "e"
        )

        #expect(manager.toolTip(at: try center(of: NSRange(location: 6, length: 5), in: textView)) == "Ipsum")
        #expect(manager.toolTip(at: try center(of: NSRange(location: 0, length: 5), in: textView)) == nil)
    }

    @Test()
    @MainActor
    func anEmphasisWithoutAToolTipRegistersNone() throws {
        let textView = makeLaidOutTextView()
        let manager = try #require(textView.emphasisManager)

        manager.addEmphasis(Emphasis(range: NSRange(location: 0, length: 5), style: .underline(color: .red)), for: "e")

        #expect(manager.toolTip(at: try center(of: NSRange(location: 0, length: 5), in: textView)) == nil)
    }

    @Test()
    @MainActor
    func removingAGroupRemovesItsToolTips() throws {
        let textView = makeLaidOutTextView()
        let manager = try #require(textView.emphasisManager)
        let point = try center(of: NSRange(location: 0, length: 5), in: textView)

        manager.addEmphasis(Emphasis(range: NSRange(location: 0, length: 5), toolTip: "Lorem"), for: "e")
        manager.removeEmphases(for: "e")

        #expect(manager.toolTip(at: point) == nil)
    }

    @Test()
    @MainActor
    func anEmphasisWhoseTextIsGoneLosesItsToolTip() throws {
        let textView = makeLaidOutTextView()
        let manager = try #require(textView.emphasisManager)
        let point = try center(of: NSRange(location: 6, length: 5), in: textView)
        manager.addEmphasis(Emphasis(range: NSRange(location: 6, length: 5), toolTip: "Ipsum"), for: "e")

        textView.textStorage.replaceCharacters(in: NSRange(location: 5, length: 6), with: "")
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        manager.updateLayerBackgrounds()

        #expect(manager.toolTip(at: point) == nil)
    }

    @Test()
    @MainActor
    func aToolTipFollowsItsTextWhenTheLayoutMoves() throws {
        let textView = TextView(string: "Lorem\nIpsum")
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 200)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 200)))
        let manager = try #require(textView.emphasisManager)
        let range = NSRange(location: 6, length: 5)
        manager.addEmphasis(Emphasis(range: range, style: .underline(color: .red), toolTip: "Ipsum"), for: "e")
        let before = try center(of: range, in: textView)

        textView.layoutManager.lineHeightMultiplier = 3
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 200)))
        manager.updateLayerBackgrounds()
        let after = try center(of: range, in: textView)

        #expect(after.y > before.y)
        #expect(manager.toolTip(at: after) == "Ipsum")
    }

    @Test()
    @MainActor
    func anUnderlineOnALineNotYetLaidOutIsDrawnOnceItIs() throws {
        let textView = TextView(string: "")
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 10_000)
        textView.setText((1...200).map { "line \($0)" }.joined(separator: "\n"))
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        let manager = try #require(textView.emphasisManager)
        let range = (textView.string as NSString).range(of: "line 150")
        let sublayersBefore = textView.layer?.sublayers?.count ?? 0
        #expect(textView.layoutManager.rectsFor(range: range).isEmpty)

        manager.addEmphasis(Emphasis(range: range, style: .underline(color: .red), toolTip: "Line"), for: "e")
        #expect((textView.layer?.sublayers?.count ?? 0) == sublayersBefore)

        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 10_000)))
        manager.updateLayerBackgrounds()

        let underline = try #require(textView.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        #expect(textView.layer?.sublayers?.count == sublayersBefore + 2)
        #expect(underline.path != nil)
        #expect(underline.lineWidth == 1)
        #expect(underline.strokeColor != nil)
        #expect(underline.isHidden == false)
        #expect(manager.toolTip(at: try center(of: range, in: textView)) == "Line")
    }

    @MainActor
    private func center(of range: NSRange, in textView: TextView) throws -> CGPoint {
        let rect = try #require(textView.layoutManager.rectsFor(range: range).first)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @MainActor
    private func makeLaidOutTextView() -> TextView {
        let textView = TextView(string: "Lorem Ipsum")
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        return textView
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
