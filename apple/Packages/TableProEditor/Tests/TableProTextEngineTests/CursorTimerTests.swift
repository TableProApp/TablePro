import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct CursorTimerTests {
    @Test("A reset with no drawn caret schedules nothing")
    func resetWithoutCaretSchedulesNothing() {
        let timer = CursorTimer()
        timer.resetTimer()
        #expect(!timer.isRunning)
    }

    @Test("Registering a caret after a reset starts the timer")
    func registerAfterResetStarts() {
        let timer = CursorTimer()
        let cursor = CursorView()
        timer.resetTimer()
        timer.register(cursor)
        #expect(timer.isRunning)
        #expect(!cursor.isHidden)
        timer.stopTimer()
    }

    @Test("A reset with a caret registered starts the timer")
    func resetWithCaretStarts() {
        let timer = CursorTimer()
        let cursor = CursorView()
        timer.resetTimer()
        timer.register(cursor)
        timer.resetTimer()
        #expect(timer.isRunning)
        timer.stopTimer()
    }

    @Test("Registering a caret while stopped keeps the timer off")
    func registerWhileStoppedKeepsOff() {
        let timer = CursorTimer()
        let cursor = CursorView()
        timer.resetTimer()
        timer.stopTimer()
        timer.register(cursor)
        #expect(!timer.isRunning)
    }

    @Test("A reset to never blink hides the caret and schedules nothing")
    func neverBlinkSchedulesNothing() {
        let timer = CursorTimer()
        let cursor = CursorView()
        timer.resetTimer()
        timer.register(cursor)
        timer.resetTimer(newBlinkDuration: nil)
        #expect(!timer.isRunning)
        #expect(cursor.isHidden)
        timer.register(CursorView())
        #expect(!timer.isRunning)
    }

    @Test("stopTimer ends the timer and hides the caret")
    func stopEnds() {
        let timer = CursorTimer()
        let cursor = CursorView()
        timer.resetTimer()
        timer.register(cursor)
        timer.stopTimer()
        #expect(!timer.isRunning)
        #expect(cursor.isHidden)
    }

    @Test("A tick blinks a registered caret")
    func tickBlinks() {
        let timer = CursorTimer()
        let cursor = CursorView()
        timer.resetTimer()
        timer.register(cursor)
        timer.tick()
        #expect(cursor.isHidden)
        timer.tick()
        #expect(!cursor.isHidden)
        #expect(timer.isRunning)
        timer.stopTimer()
    }

    @Test("A released caret ends the timer at the next tick")
    func releasedCaretEndsTimer() {
        let timer = CursorTimer()
        timer.resetTimer()
        autoreleasepool {
            let cursor = CursorView()
            timer.register(cursor)
        }
        #expect(timer.isRunning)
        timer.tick()
        #expect(!timer.isRunning)
    }

    @available(macOS 14, *)
    @Test("A focused view with the system caret runs no timer")
    func systemCaretRunsNoTimer() {
        let textView = focusedTextView(useSystemCursor: true)
        #expect(textView.selectionManager.textSelections.first?.view is NSTextInsertionIndicator)
        #expect(!textView.selectionManager.cursorTimer.isRunning)
    }

    @Test("A focused view with the drawn caret runs the timer")
    func drawnCaretRunsTimer() {
        let textView = focusedTextView(useSystemCursor: false)
        #expect(textView.selectionManager.textSelections.first?.view is CursorView)
        #expect(textView.selectionManager.cursorTimer.isRunning)
        textView.selectionManager.removeCursors()
        #expect(!textView.selectionManager.cursorTimer.isRunning)
    }

    private func focusedTextView(useSystemCursor: Bool) -> TextView {
        let textView = TextView(string: "Lorem Ipsum")
        textView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        textView.layoutSubtreeIfNeeded()
        textView.useSystemCursor = useSystemCursor
        textView.isFirstResponder = true
        textView.selectionManager.cursorTimer.resetTimer()
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.selectionManager.updateSelectionViews(force: true, skipTimerReset: true)
        return textView
    }
}
