//
//  VimEngineMacroTests.swift
//  TableProTests
//
//  Spec for macro recording and playback: q{a-z} starts/stops recording, @{a-z}
//  replays a named macro, @@ replays the last replayed macro.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineMacroTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "aaa bbb ccc ddd\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - Recording

    @Test
    func qStartsRecordingIntoNamedRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        // After recording, the buffer should reflect the recorded edit once.
        #expect(buffer.text == "bbb ccc ddd\n",
            "Recording the macro should still execute the keys")
    }

    @Test
    func qAtoQClosesRecording() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("x")
        keys("q")
        // Now type 'x' again — it should NOT be recorded (recording is closed).
        keys("x")
        #expect(buffer.text == "a bbb ccc ddd\n",
            "Recording stops on the second q; subsequent keys must not be appended")
    }

    // MARK: - Playback

    @Test
    func atAReplaysNamedMacro() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        #expect(buffer.text == "bbb ccc ddd\n")
        keys("@a")
        #expect(buffer.text == "ccc ddd\n",
            "@a should replay the recorded dw once")
    }

    @Test
    func atACanBeReplayedMultipleTimes() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        keys("@a")
        keys("@a")
        #expect(buffer.text == "ddd\n", "Three deletions total: 1 recording + 2 replays")
    }

    @Test
    func atAtReplaysLastMacro() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        keys("@a")
        keys("@@")
        #expect(buffer.text == "ddd\n",
            "@@ should replay the most recently invoked macro")
    }

    @Test
    func atAWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        keys("3@a")
        #expect(buffer.text == "\n",
            "3@a should replay the macro three times")
    }

    // MARK: - Multiple Macros

    @Test
    func twoIndependentMacros() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("w")
        keys("q")
        #expect(pos == 4)
        keys("qb")
        keys("dw")
        keys("q")
        #expect(buffer.text == "aaa ccc ddd\n",
            "Macro 'b' should run once during recording")
        keys("0@a")
        #expect(pos == 4, "Macro 'a' should still advance by one word when invoked")
    }

    // MARK: - Empty Macro

    @Test
    func emptyMacroReplayIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("q")
        let snapshot = buffer.text
        keys("@a")
        #expect(buffer.text == snapshot, "Replaying an empty macro should be a no-op")
    }

    // MARK: - Recording During Visual Mode

    @Test
    func recordingCapturesVisualOperation() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("v")
        keys("ll")
        keys("d")
        keys("q")
        // Buffer should reflect one visual delete.
        #expect(buffer.text == " bbb ccc ddd\n")
        // Replay should perform another visual-style delete from the current cursor.
        keys("@a")
        // The exact result depends on cursor position, but it should mutate the buffer.
        #expect(buffer.text != " bbb ccc ddd\n",
            "@a after recording a visual delete should re-execute and change the buffer")
    }

    // MARK: - Recursive Macro Safety

    @Test
    func recursiveMacroDoesNotInfiniteLoop() {
        // Set up a macro that includes a self-reference.
        buffer = VimTextBufferMock(text: "abcd\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("x@a")
        keys("q")
        // The recording itself runs once. The trailing @a inside the macro should
        // not crash, even if not bounded — engines normally cap recursion depth.
        #expect(buffer.text != nil)
    }
}
