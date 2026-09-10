import AppKit
import Testing
@testable import CodeEditTextView

/// The line storage is updated from the edited range and can be longer than the string it indexes
/// while an edit is still in flight. Slicing the storage with a range from the far side of that
/// raises `NSRangeException`, and this runs inside the layout pass.
@Suite()
struct TextLineDisplayRangeTests {
    @Test()
    @MainActor
    func aLineWhoseRangeOutrunsTheStringIsLeftForTheNextLayoutPass() {
        let storage = NSTextStorage(string: "Hello")
        let line = TextLine()

        line.prepareForDisplay(
            displayData: TextLine.DisplayData(maxWidth: 1_000, lineHeightMultiplier: 1.0, estimatedLineHeight: 14),
            range: NSRange(location: 3, length: 40),
            stringRef: storage,
            markedRanges: nil,
            attachments: []
        )

        #expect(line.needsLayout(maxWidth: 1_000))
        #expect(line.lineFragments.isEmpty)
    }

    @Test()
    @MainActor
    func aLineWhoseRangeFitsIsTypeset() {
        let storage = NSTextStorage(string: "Hello")
        let line = TextLine()

        line.prepareForDisplay(
            displayData: TextLine.DisplayData(maxWidth: 1_000, lineHeightMultiplier: 1.0, estimatedLineHeight: 14),
            range: NSRange(location: 0, length: 5),
            stringRef: storage,
            markedRanges: nil,
            attachments: []
        )

        #expect(line.lineFragments.isEmpty == false)
    }
}
