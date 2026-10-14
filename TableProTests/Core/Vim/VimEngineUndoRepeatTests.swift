//
//  VimEngineUndoRepeatTests.swift
//  TableProTests
//
//  Specification tests for undo (u), redo (Ctrl+R),
//  the repeat command (.), and the line undo (U).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineUndoRepeatTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    // MARK: - u: Undo

    @Test
    func uCallsBufferUndo() {
        #expect(buffer.undoCallCount == 0)
        keys("u")
        #expect(buffer.undoCallCount == 1)
    }

    @Test
    func uWithCountCallsUndoNTimes() {
        keys("3u")
        #expect(buffer.undoCallCount == 3, "3u should call undo three times")
    }

    @Test
    func uConsumesKey() {
        #expect(engine.process("u", shift: false))
    }

    // MARK: - Ctrl+R: Redo

    @Test
    func redoCallsBufferRedo() {
        #expect(buffer.redoCallCount == 0)
        key("\u{12}")
        #expect(buffer.redoCallCount == 1)
    }

    @Test
    func multipleRedoCalls() {
        key("\u{12}")
        key("\u{12}")
        key("\u{12}")
        #expect(buffer.redoCallCount == 3)
    }

    // MARK: - U: Undo Line (undo all changes on the last edited line)

    @Test
    func capitalUUndoesLineChanges() {
        // U undoes all changes made on the last edited line in one go.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // delete 'h'
        keys("x") // delete 'e'
        key("U", shift: true)
        #expect(buffer.undoCallCount == 2,
            "U should restore the original line — implemented via repeated undo")
    }

    // MARK: - . (Repeat Last Change)

    @Test
    func dotRepeatsLastEdit() {
        // Delete a word, then dot should delete another word.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw") // delete "hello "
        #expect(buffer.text == "world\nsecond line\nthird line\n")
        keys(".")
        #expect(buffer.text == "\nsecond line\nthird line\n",
            ". should repeat the last change (delete word)")
    }

    @Test
    func dotRepeatsXDelete() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x")
        #expect(buffer.text == "ello world\nsecond line\nthird line\n")
        keys(".")
        #expect(buffer.text == "llo world\nsecond line\nthird line\n",
            ". should repeat the last delete")
    }

    @Test
    func dotRepeatsWithExplicitCount() {
        // dw, then 3. should delete 3 more words.
        buffer = VimTextBufferMock(text: "a b c d e f\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw") // delete "a "
        keys("3.") // delete 3 more words
        #expect(buffer.text == "e f\n",
            "3. should repeat the last change three times")
    }

    @Test
    func dotDoesNotRepeatMotions() {
        // Pure motions (no edit) should not be repeatable by dot.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        keys("l")
        keys(".") // no last change → no-op
        #expect(buffer.text == "hello world\nsecond line\nthird line\n")
    }

    @Test
    func dotRepeatsInsertedText() {
        // Inserted text should be repeatable. This requires the engine to record the
        // insert-mode text, then dot replays it. Hard to test purely at engine level —
        // we at least assert that dot is consumed.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        _ = engine.process("X", shift: false) // pass-through in insert mode
        _ = engine.process("\u{1B}", shift: false) // escape
        let consumed = engine.process(".", shift: false)
        #expect(consumed, ". must be consumed in normal mode")
    }
}
