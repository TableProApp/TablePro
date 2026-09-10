import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct WordSelectionTests {
    let text = "SELECT firstname FROM users"

    func makeTextView(isEditable: Bool = true) -> TextView {
        let textView = TextView(string: text)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    func offset(ofWord word: String) -> Int {
        (text as NSString).range(of: word).location
    }

    func mouseDown(on textView: TextView, atOffset offset: Int, clickCount: Int) {
        guard let rect = textView.layoutManager.rectForOffset(offset) else {
            Issue.record("No rect for offset \(offset)")
            return
        }
        let point = textView.convert(CGPoint(x: rect.midX + 1, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        ) else {
            Issue.record("Could not build a mouse event")
            return
        }
        textView.mouseDown(with: event)
    }

    @Test
    func selectWordKeepsAWordWhenTheSelectionIsNotEmpty() {
        let textView = makeTextView()
        let firstname = (text as NSString).range(of: "firstname")
        textView.selectionManager.setSelectedRange(firstname)

        textView.selectWord(nil)

        #expect(textView.selectionManager.textSelections.count == 1)
        #expect(textView.selectionManager.textSelections.first?.range == firstname)
    }

    @Test
    func doubleClickSelectsTheWordUnderThePointer() {
        let textView = makeTextView()

        mouseDown(on: textView, atOffset: offset(ofWord: "firstname"), clickCount: 1)
        mouseDown(on: textView, atOffset: offset(ofWord: "firstname"), clickCount: 2)

        #expect(textView.selectionManager.textSelections.first?.range == (text as NSString).range(of: "firstname"))
    }

    @Test
    func doubleClickSelectsTheWordEvenWhenAnotherSelectionExists() {
        let textView = makeTextView()
        textView.selectionManager.setSelectedRange((text as NSString).range(of: "SELECT firstname"))

        mouseDown(on: textView, atOffset: offset(ofWord: "users"), clickCount: 2)

        #expect(textView.selectionManager.textSelections.first?.range == (text as NSString).range(of: "users"))
    }

    @Test
    func doubleClickSelectsAWordWhenNothingIsSelected() {
        let textView = makeTextView()
        textView.selectionManager.setSelectedRanges([])

        mouseDown(on: textView, atOffset: offset(ofWord: "users"), clickCount: 2)

        #expect(textView.selectionManager.textSelections.first?.range == (text as NSString).range(of: "users"))
    }

    @Test
    func wordBoundaryTreatsTheEndOfTheDocumentAsABoundary() {
        let textView = makeTextView()

        let range = textView.findWordBoundary(at: offset(ofWord: "users"))

        #expect(range == (text as NSString).range(of: "users"))
    }

    @Test
    func wordBoundaryTreatsTheStartOfTheDocumentAsABoundary() {
        let textView = makeTextView()

        let range = textView.findWordBoundary(at: 0)

        #expect(range == (text as NSString).range(of: "SELECT"))
    }

    @Test
    func tripleClickSelectsTheLineUnderThePointer() {
        let textView = TextView(string: "first line\nsecond line\n")
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        textView.layoutSubtreeIfNeeded()

        mouseDown(on: textView, atOffset: 14, clickCount: 3)

        let selected = textView.selectionManager.textSelections.first?.range
        #expect(selected == NSRange(location: 11, length: 12))
    }

    @Test
    func singleClickPlacesTheSelectionInANonEditableView() {
        let textView = makeTextView(isEditable: false)
        let target = offset(ofWord: "users")

        mouseDown(on: textView, atOffset: target, clickCount: 1)

        #expect(textView.selectionManager.textSelections.count == 1)
        #expect(textView.selectionManager.textSelections.first?.range.isEmpty == true)
    }

    @Test
    func doubleClickSelectsAWordInANonEditableView() {
        let textView = makeTextView(isEditable: false)

        mouseDown(on: textView, atOffset: offset(ofWord: "firstname"), clickCount: 2)

        #expect(textView.selectionManager.textSelections.first?.range == (text as NSString).range(of: "firstname"))
    }
}
