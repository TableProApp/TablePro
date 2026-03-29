import Testing
import Foundation
@testable import CodeEditTextView

@Suite()
struct EmphasisManagerTests {
    @Test()
    @MainActor
    func testFlashEmphasisLayersNotLeaked() {
        // Ensure layers are not leaked when switching from flash emphasis to any other emphasis type.
        let textView = TextView(string: "Lorem Ipsum")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 100)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1000, height: 100)))
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
}
