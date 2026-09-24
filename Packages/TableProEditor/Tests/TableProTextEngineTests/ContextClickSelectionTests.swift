import AppKit
@testable import TableProTextEngine
import Testing

@Suite
@MainActor
struct ContextClickSelectionTests {
    private func makeLaidOutTextView() -> TextView {
        let text = (0..<40)
            .map { "SELECT column_\($0) FROM some_table WHERE id = \($0);" }
            .joined(separator: "\n")
        let textView = TextView(string: text)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.wrapLines = false
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_200)
        textView.updateFrameIfNeeded()
        textView.frame.size.width = 900
        textView.layoutManager.invalidateLayoutForRange(textView.documentRange)
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 900, height: 1_200))
        return textView
    }

    private func rightClick(at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    @Test("A right-click outside the selection records the word it selected")
    func recordsSelectedWord() throws {
        let textView = makeLaidOutTextView()
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))

        _ = textView.menu(for: try rightClick(at: NSPoint(x: 40, y: 20)))

        let word = try #require(textView.contextClickWordRange)
        #expect(word.length > 0)
        #expect(NSEqualRanges(textView.selectedRange(), word))
    }

    @Test("A right-click inside the selection leaves it and records no word")
    func keepsSelectionInside() throws {
        let textView = makeLaidOutTextView()
        textView.selectionManager.setSelectedRange(textView.documentRange)

        _ = textView.menu(for: try rightClick(at: NSPoint(x: 40, y: 20)))

        #expect(textView.contextClickWordRange == nil)
        #expect(NSEqualRanges(textView.selectedRange(), textView.documentRange))
    }
}
