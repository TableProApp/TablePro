import AppKit
@testable import TableProEditorKit
import Testing

@MainActor
struct VisibleRangeProviderTests {
    @MainActor
    @Test func test_updateOnScroll() {
        let (scrollView, textView) = Mock.scrollingTextView()
        textView.string = Array(repeating: "\n", count: 400).joined()
        textView.layout()

        let rangeProvider = VisibleRangeProvider(textView: textView)
        let originalSet = rangeProvider.visibleSet

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 250))

        scrollView.layoutSubtreeIfNeeded()
        textView.layout()

        #expect(originalSet != rangeProvider.visibleSet)
    }

    @MainActor
    @Test func test_updateOnResize() {
        let (scrollView, textView) = Mock.scrollingTextView()
        textView.string = Array(repeating: "\n", count: 400).joined()
        textView.layout()

        let rangeProvider = VisibleRangeProvider(textView: textView)
        let originalSet = rangeProvider.visibleSet

        scrollView.setFrameSize(NSSize(width: 250, height: 450))

        scrollView.layoutSubtreeIfNeeded()
        textView.layout()

        #expect(originalSet != rangeProvider.visibleSet)
    }

    @MainActor
    @Test func test_noScrollViewMakesTheWholeDocumentVisible() {
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView.string = Array(repeating: "\n", count: 400).joined()
        textView.layout()

        let rangeProvider = VisibleRangeProvider(textView: textView)
        let wholeDocument = IndexSet(integersIn: rangeProvider.documentRange)

        #expect(rangeProvider.visibleSet == wholeDocument)

        textView.setFrameSize(NSSize(width: 350, height: 450))
        textView.layout()

        #expect(rangeProvider.visibleSet == wholeDocument)
    }
}
