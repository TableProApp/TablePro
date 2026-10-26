//
//  GutterSelectionObserverTests.swift
//  TableProEditorKitTests
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct GutterSelectionObserverTests {
    // NotificationCenter holds a block observer's token until it is removed, so a surviving token is a leaked block.
    @Test("A closed gutter's selection observer is removed")
    func observerIsRemovedWithTheGutter() {
        let controller = Mock.textViewController(theme: Mock.theme())
        weak var token: AnyObject?

        autoreleasepool {
            let gutter = GutterView(
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                textColor: .labelColor,
                selectedTextColor: nil,
                controller: controller
            )
            token = gutter.selectionObserver as AnyObject?
            #expect(token != nil)
        }

        #expect(token == nil)
    }

    @Test("A selection change in another editor does not redraw this gutter")
    func otherEditorsSelectionLeavesGutterAlone() {
        let first = Mock.loadedTextViewController(string: "a\nb\nc")
        let second = Mock.loadedTextViewController(string: "x\ny\nz")
        let gutter = CountingGutter(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: .labelColor,
            selectedTextColor: nil,
            controller: first
        )
        let before = gutter.redraws

        second.textView.selectionManager.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(gutter.redraws == before)

        first.textView.selectionManager.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(gutter.redraws > before)
    }
}

// `needsDisplay` does not read back on a layer-backed view outside a window, but setting it goes through this.
private final class CountingGutter: GutterView {
    private(set) var redraws = 0

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        redraws += 1
        super.setNeedsDisplay(invalidRect)
    }
}
