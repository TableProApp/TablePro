import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct UndoBudgetTests {
    private static let step = String(repeating: "x", count: 1_000)

    private func makeTextView() throws -> (TextView, CEUndoManager) {
        let textView = TextView(string: "")
        return (textView, try #require(textView.editorUndoManager))
    }

    // One undo step per call, as a paste or a Format Query is.
    private func appendStep(_ text: String, to textView: TextView, undoManager: CEUndoManager) {
        undoManager.beginUndoGrouping()
        textView.replaceCharacters(in: NSRange(location: textView.textStorage.length, length: 0), with: text)
        undoManager.endUndoGrouping()
    }

    private func stepBytes(_ undoManager: CEUndoManager) -> Int {
        undoManager.historyBytes / max(undoManager.undoCount + undoManager.redoCount, 1)
    }

    @Test("Steps past the budget drop the oldest, and the newest still undo in order")
    func oldestStepsAreDropped() throws {
        let (textView, undoManager) = try makeTextView()
        appendStep(Self.step, to: textView, undoManager: undoManager)
        let perStep = stepBytes(undoManager)
        undoManager.maximumHistoryBytes = perStep * 3

        for _ in 1..<10 {
            appendStep(Self.step, to: textView, undoManager: undoManager)
            #expect(undoManager.historyBytes <= undoManager.maximumHistoryBytes)
        }

        #expect(undoManager.undoCount == 3)
        for remaining in [9, 8, 7] {
            undoManager.undo()
            #expect(textView.textStorage.length == remaining * Self.step.count)
        }
        #expect(!undoManager.canUndo)
    }

    @Test("A step larger than the whole budget is kept, so it can still be undone")
    func oversizedStepIsKept() throws {
        let (textView, undoManager) = try makeTextView()
        undoManager.maximumHistoryBytes = 100
        appendStep("SELECT 1", to: textView, undoManager: undoManager)

        appendStep(Self.step, to: textView, undoManager: undoManager)

        #expect(undoManager.undoCount == 1)
        undoManager.undo()
        #expect(textView.string == "SELECT 1")
        #expect(!undoManager.canUndo)
    }

    @Test("A whole-document replace is charged both the old and the new text")
    func replaceChargesBothSides() throws {
        let (textView, undoManager) = try makeTextView()
        appendStep(Self.step, to: textView, undoManager: undoManager)
        let insertOnly = undoManager.historyBytes

        undoManager.beginUndoGrouping()
        textView.replaceCharacters(in: NSRange(location: 0, length: textView.textStorage.length), with: Self.step)
        undoManager.endUndoGrouping()

        let replace = undoManager.historyBytes - insertOnly
        #expect(replace >= Self.step.utf16.count * 2 * MemoryLayout<UInt16>.size)
    }

    @Test("The redo stack counts toward the budget, and a restored history is trimmed to it")
    func redoStackIsBounded() throws {
        let (textView, undoManager) = try makeTextView()
        for _ in 0..<6 {
            appendStep(Self.step, to: textView, undoManager: undoManager)
        }
        let perStep = stepBytes(undoManager)
        for _ in 0..<4 {
            undoManager.undo()
        }
        let history = undoManager.history
        #expect(history.bytes == undoManager.historyBytes)

        undoManager.clearStack()
        #expect(undoManager.historyBytes == 0)
        undoManager.maximumHistoryBytes = perStep * 3
        undoManager.restore(history)

        // The two undo steps are older than the four redo steps, so they go first, then the furthest redo.
        #expect(undoManager.undoCount == 0)
        #expect(undoManager.redoCount == 3)
        #expect(undoManager.historyBytes <= undoManager.maximumHistoryBytes)
        undoManager.redo()
        #expect(textView.textStorage.length == 3 * Self.step.count)
    }

    @Test("A budget of zero keeps every step")
    func zeroBudgetIsUnlimited() throws {
        let (textView, undoManager) = try makeTextView()
        undoManager.maximumHistoryBytes = 0
        for _ in 0..<50 {
            appendStep(Self.step, to: textView, undoManager: undoManager)
        }
        #expect(undoManager.undoCount == 50)
    }
}
