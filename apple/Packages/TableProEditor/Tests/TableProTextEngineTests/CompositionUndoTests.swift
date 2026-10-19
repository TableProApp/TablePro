import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct CompositionUndoTests {
    private static let notFound = NSRange(location: NSNotFound, length: 0)

    private func makeTextView(_ text: String, selection: NSRange) -> TextView {
        let textView = TextView(string: text)
        textView.selectionManager.setSelectedRange(selection)
        return textView
    }

    private func setMarked(_ text: String, in textView: TextView, replacing range: NSRange = notFound) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: range
        )
    }

    private func undoAll(_ textView: TextView) {
        var remaining = 10
        while textView.undoManager?.canUndo == true, remaining > 0 {
            textView.undoManager?.undo()
            remaining -= 1
        }
    }

    @Test
    func oneUndoRemovesACommittedDeadKey() {
        let textView = makeTextView("ab", selection: NSRange(location: 1, length: 0))

        setMarked("´", in: textView)
        textView.insertText("é", replacementRange: Self.notFound)
        textView.undoManager?.undo()

        #expect(textView.string == "ab")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test
    func compositionStagesAreNotUndoSteps() {
        let textView = makeTextView("ab", selection: NSRange(location: 1, length: 0))

        for stage in ["k", "ka", "kan"] {
            setMarked(stage, in: textView)
        }
        textView.insertText("缶", replacementRange: Self.notFound)
        #expect(textView.string == "a缶b")

        textView.undoManager?.undo()

        #expect(textView.string == "ab")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test
    func unmarkTextKeepsTheCompositionAsTypedText() {
        let textView = makeTextView("ab", selection: NSRange(location: 1, length: 0))

        setMarked("´", in: textView)
        textView.unmarkText()

        #expect(textView.string == "a´b")
        #expect(textView.hasMarkedText() == false)
        #expect(textView.selectionManager.textSelections.map(\.range) == [NSRange(location: 2, length: 0)])

        textView.undoManager?.undo()
        #expect(textView.string == "ab")
    }

    @Test
    func compositionLeftByMovingTheCaretIsUndoable() {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 0))

        setMarked("´", in: textView)
        textView.selectionManager.setSelectedRange(NSRange(location: 4, length: 0))
        textView.unmarkTextIfNeeded()
        #expect(textView.string == "a´bc")
        #expect(textView.hasMarkedText() == false)

        textView.undoManager?.undo()
        #expect(textView.string == "abc")
    }

    @Test
    func undoRestoresTheSelectionACompositionReplaced() {
        let textView = makeTextView("ABCDE", selection: NSRange(location: 4, length: 1))

        setMarked("´", in: textView)
        textView.insertText("é", replacementRange: Self.notFound)
        #expect(textView.string == "ABCDé")

        undoAll(textView)
        #expect(textView.string == "ABCDE")
    }

    @Test
    func cancelledCompositionOverASelectionUndoesBackToTheSelection() {
        let textView = makeTextView("ABCDE", selection: NSRange(location: 4, length: 1))

        setMarked("´", in: textView)
        setMarked("", in: textView)
        #expect(textView.string == "ABCD")

        textView.undoManager?.undo()
        #expect(textView.string == "ABCDE")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test
    func commitAtTouchingSelectionsKeepsEveryCommit() {
        let textView = TextView(string: "AB")
        textView.selectionManager.setSelectedRanges([
            NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 1)
        ])

        setMarked("´", in: textView)
        #expect(textView.string == "´´")
        textView.insertText("é", replacementRange: Self.notFound)
        #expect(textView.string == "éé")

        undoAll(textView)
        #expect(textView.string == "AB")
    }

    @Test
    func compositionBegunAtAnExplicitRangeIsMarkedThere() {
        let textView = makeTextView("hello world", selection: NSRange(location: 11, length: 0))

        setMarked("かんじ", in: textView, replacing: NSRange(location: 6, length: 5))

        #expect(textView.string == "hello かんじ")
        #expect(textView.markedRange() == NSRange(location: 6, length: 3))

        textView.insertText("漢字", replacementRange: Self.notFound)
        #expect(textView.string == "hello 漢字")
        #expect(textView.selectionManager.textSelections.map(\.range) == [NSRange(location: 8, length: 0)])

        undoAll(textView)
        #expect(textView.string == "hello world")
    }
}
