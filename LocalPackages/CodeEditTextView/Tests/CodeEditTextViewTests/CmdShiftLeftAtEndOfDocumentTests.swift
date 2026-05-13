import AppKit
@testable import CodeEditTextView
import Testing

/// Regression tests for word-granularity selection extension when the cursor
/// sits at the very end of the document. Standard macOS NSTextView behavior:
///   - Cmd+Shift+Left at the end of "select * from products" extends the
///     selection backward to cover the last word "products".
///   - Cmd+Left at the end jumps the caret to the start of the last word.
///
/// Issue #1075: cursor at end of buffer with no preceding selection cannot
/// extend selection backward by word.
@Suite
@MainActor
struct CmdShiftLeftAtEndOfDocumentTests {
    private func makeLaidOutTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        return textView
    }

    // MARK: - rangeOfSelection (pure range computation)

    @Test("Cmd+Left at end of single-line query returns range covering last word")
    func cmdLeftRangeAtEndOfSingleLine() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .backward,
            destination: .word
        )

        #expect(range == NSRange(location: 14, length: 8))
    }

    @Test("Cmd+Left at end of multi-line query returns range covering last word")
    func cmdLeftRangeAtEndOfMultiLine() {
        let textView = makeLaidOutTextView("select *\nfrom products")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .backward,
            destination: .word
        )

        #expect(range == NSRange(location: 14, length: 8))
    }

    // MARK: - Full moveWordLeftAndModifySelection flow (covers pivot logic)

    @Test("Cmd+Shift+Left at end of single-line query selects the last word")
    func cmdShiftLeftSelectsLastWordAtEnd() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))
        textView.moveWordLeftAndModifySelection(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        #expect(selection.range == NSRange(location: 14, length: 8))
    }

    @Test("Cmd+Shift+Left twice at end extends across two words")
    func cmdShiftLeftTwiceExtendsAcrossTwoWords() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))
        textView.moveWordLeftAndModifySelection(nil)
        textView.moveWordLeftAndModifySelection(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        // Selection should now cover "from products" — from offset 9 to 22.
        #expect(selection.range == NSRange(location: 9, length: 13))
    }

    @Test("Cmd+Left at end moves caret to start of last word")
    func cmdLeftMovesCaretToStartOfLastWord() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))
        textView.moveWordLeft(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        #expect(selection.range == NSRange(location: 14, length: 0))
    }

    // MARK: - Pivot reset across separate selection sessions

    /// Reproduces the user's likely workflow: extend selection forward,
    /// click somewhere else (caret reset), then try to extend backward.
    /// The stale pivot from the prior session must not leak into the new one.
    @Test("After click-resetting caret to end, Cmd+Shift+Left selects last word")
    func clickResetsPivotForBackwardExtension() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        // Session 1: cursor at start, extend forward by word.
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.moveWordRightAndModifySelection(nil)

        // Session 2: user clicks at end (caret reset).
        textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))

        // Cmd+Shift+Left should select the last word.
        textView.moveWordLeftAndModifySelection(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        #expect(selection.range == NSRange(location: 14, length: 8))
    }

    // MARK: - Cmd+Left / Cmd+Shift+Left at end (line-granularity, NOT word)

    /// Cmd+Left on macOS is `moveToBeginningOfLine:` — line-start, not word.
    /// At the end of a single-line buffer, the caret should jump to offset 0.
    @Test("Cmd+Left at end of single-line moves caret to line start (offset 0)")
    func cmdLeftAtEndJumpsToLineStart() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))
        textView.moveToBeginningOfLine(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        #expect(selection.range == NSRange(location: 0, length: 0))
    }

    /// Cmd+Shift+Left at the end of a single-line buffer should extend the
    /// selection backward to offset 0 — selecting the entire line.
    @Test("Cmd+Shift+Left at end of single-line selects entire line")
    func cmdShiftLeftAtEndSelectsEntireLine() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))
        textView.moveToBeginningOfLineAndModifySelection(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        #expect(selection.range == NSRange(location: 0, length: length))
    }

    @Test("Pressing End then Cmd+Shift+Left selects last word")
    func endThenCmdShiftLeftSelectsLastWord() {
        let textView = makeLaidOutTextView("select * from products")
        let length = (textView.string as NSString).length

        // Start somewhere in the middle.
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        // Press End — moveToEndOfLine.
        textView.moveToEndOfLine(nil)

        guard let afterEnd = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection after End")
            return
        }
        #expect(afterEnd.range == NSRange(location: length, length: 0))

        // Now Cmd+Shift+Left.
        textView.moveWordLeftAndModifySelection(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        #expect(selection.range == NSRange(location: 14, length: 8))
    }
}
