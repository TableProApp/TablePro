import XCTest
@testable import CodeEditSourceEditor

final class VisibleRangeProviderTests: XCTestCase {
    @MainActor
    func test_updateOnScroll() {
        let (scrollView, textView) = Mock.scrollingTextView()
        textView.string = Array(repeating: "\n", count: 400).joined()
        textView.layout()

        let rangeProvider = VisibleRangeProvider(textView: textView, minimapView: nil)
        let originalSet = rangeProvider.visibleSet

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 250))

        scrollView.layoutSubtreeIfNeeded()
        textView.layout()

        XCTAssertNotEqual(originalSet, rangeProvider.visibleSet)
    }

    @MainActor
    func test_updateOnResize() {
        let (scrollView, textView) = Mock.scrollingTextView()
        textView.string = Array(repeating: "\n", count: 400).joined()
        textView.layout()

        let rangeProvider = VisibleRangeProvider(textView: textView, minimapView: nil)
        let originalSet = rangeProvider.visibleSet

        scrollView.setFrameSize(NSSize(width: 250, height: 450))

        scrollView.layoutSubtreeIfNeeded()
        textView.layout()

        XCTAssertNotEqual(originalSet, rangeProvider.visibleSet)
    }

    // Skipping due to a bug in the textview that returns all indices for the visible rect
    // when not in a scroll view

    @MainActor
    func _test_updateOnResizeNoScrollView() {
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView.string = Array(repeating: "\n", count: 400).joined()
        textView.layout()

        let rangeProvider = VisibleRangeProvider(textView: textView, minimapView: nil)
        let originalSet = rangeProvider.visibleSet

        textView.setFrameSize(NSSize(width: 350, height: 450))

        textView.layout()

        XCTAssertNotEqual(originalSet, rangeProvider.visibleSet)
    }
}
