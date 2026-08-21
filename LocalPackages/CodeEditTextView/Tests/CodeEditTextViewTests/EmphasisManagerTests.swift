import Testing
import Foundation
@testable import CodeEditTextView

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

    @MainActor
    private func makeLaidOutTextView() -> TextView {
        let textView = TextView(string: "Lorem Ipsum")
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        return textView
    }
}
